param([int]$IntervalSeconds=120,[switch]$Once)
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$LogPath=Join-Path $BaseDir "tt-auto-updater.log"

$Managed=@(
  @{Path="windows/TTendenciasWebImages.cjs";Local="TTendenciasWebImages.cjs";Kind="js";Pattern=""},
  @{Path="windows/TTendenciasDedicatedListener.ps1";Local="TTendenciasDedicatedListener.ps1";Kind="ps";Pattern="*TTendenciasDedicatedListener.ps1*"},
  @{Path="windows/TTendenciasImageBridge.js";Local="TTendenciasImageBridge.js";Kind="js";Pattern=""},
  @{Path="windows/TTiTTularesDedicatedListener.ps1";Local="TTiTTularesDedicatedListener.ps1";Kind="ps";Pattern="*TTiTTularesDedicatedListener.ps1*"},
  @{Path="windows/TTiTTularesImageBridge.js";Local="TTiTTularesImageBridge.js";Kind="js";Pattern=""},
  @{Path="windows/TT-LocalWatchdog.ps1";Local="TT-LocalWatchdog.ps1";Kind="ps";Pattern="*TT-LocalWatchdog.ps1*"},
  @{Path="windows/TT-Editorial-Tab-Watch.js";Local="TT-Editorial-Tab-Watch.js";Kind="js";Pattern=""},
  @{Path="windows/TT-Chrome9223-Safe-Prune.js";Local="TT-Chrome9223-Safe-Prune.js";Kind="js";Pattern=""}
)

function Log([string]$Text){
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
  $line=(Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$Text
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  # -Once is interactive maintenance: always show the exact stage and result.
  if($Once){Write-Host $line}
}

function Get-MainSha {
  # Never run unbounded "git ls-remote" in an interactive repair.
  # Only one time-limited GitHub API query per pass; RAW/main is the fallback.
  try {
    $uri="https://api.github.com/repos/fabricelop/europapress-rss/commits/main?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $doc=Invoke-RestMethod -Uri $uri -Headers @{
      "Accept"="application/vnd.github+json"
      "User-Agent"="TT-auto-updater-timeout-v7"
      "Cache-Control"="no-cache"
    } -TimeoutSec 12 -ErrorAction Stop
    $sha=[string]$doc.sha
    if($sha -match "^[0-9a-fA-F]{40}$"){return $sha.ToLowerInvariant()}
  } catch {
    Log ("MAIN SHA API WARNING :: "+$_.Exception.Message)
  }
  Log "MAIN SHA FALLBACK: RAW main (no Git blocking)"
  return ""
}

function Download-Raw([string]$Path,[string]$MainSha){
  $ref=if($MainSha){$MainSha}else{"main"}
  $uri="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$ref+"/"+$Path+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $tmp=Join-Path ([IO.Path]::GetTempPath()) ("tt-updater-"+[Guid]::NewGuid().ToString("N")+".raw")
  try{
    # WebClient.DownloadData has no bounded timeout; PowerShell's HTTP client does.
    Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $tmp -TimeoutSec 20 -Headers @{
      "User-Agent"="TT-auto-updater-timeout-v7"
      "Cache-Control"="no-cache"
    } -ErrorAction Stop | Out-Null
    [byte[]]$bytes=[IO.File]::ReadAllBytes($tmp)
    if(-not $bytes -or $bytes.Length -lt 100){throw "RAW vacio/corto: $Path ref=$ref"}
    return ,$bytes
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Sha256Bytes([byte[]]$Bytes){
  $sha= [Security.Cryptography.SHA256]::Create()
  try{
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-","").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function LocalSha([string]$File){
  if(-not (Test-Path -LiteralPath $File)){return ""}
  return Sha256Bytes ([IO.File]::ReadAllBytes($File))
}

function ValidatePs([string]$File){
  $tokens=$null;$errors=$null
  [Management.Automation.Language.Parser]::ParseFile($File,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){throw "PowerShell invalido: "+$errors[0].Message}
}

function ValidateJs([string]$File){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "Node no disponible"}
  $src=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    $src | & $node.Source --check - 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$old
  }
  if($code -ne 0){throw "JS invalido: $File"}
}

function StopMatch([string]$Pattern){
  if(-not $Pattern){return}
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and [string]$_.CommandLine -like $Pattern
  })|ForEach-Object{
    try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
  }
}

function StartListener([string]$Name){
  $file=Join-Path $BaseDir $Name
  $out=Join-Path $BaseDir ($Name+".autoupdate.out.log")
  $err=Join-Path $BaseDir ($Name+".autoupdate.err.log")
  $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$file) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  Start-Sleep -Milliseconds 900
  $p.Refresh()
  if($p.HasExited){throw "Listener no activo: $Name"}
  Log ("RESTART OK "+$Name+" pid="+$p.Id)
}

function CheckOnce {
  try{
    $restart=@()
    $watcherUpdated=$false
    $downloads=0
    $mainSha=Get-MainSha
    foreach($m in $Managed){
      $local=Join-Path $BaseDir ([string]$m.Local)
      Log ("DOWNLOAD START "+[string]$m.Path)
      $bytes=Download-Raw ([string]$m.Path) $mainSha
      $downloads++
      Log ("DOWNLOAD OK "+[string]$m.Path+" bytes="+$bytes.Length)
      $remoteSha=Sha256Bytes $bytes
      $localSha=LocalSha $local
      if($localSha -eq $remoteSha){continue}

      Log ("UPDATE DETECTED "+$m.Path+" local="+$localSha+" remote="+$remoteSha)
      $tmp=$local+".autoupdate"+$(if($m.Kind -eq "js"){".new.js"}else{".new.ps1"})
      [IO.File]::WriteAllBytes($tmp,$bytes)
      if($m.Kind -eq "ps"){ValidatePs $tmp}else{ValidateJs $tmp}
      if((LocalSha $tmp) -ne $remoteSha){
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw "SHA256 no coincide: "+$m.Path
      }
      Move-Item -LiteralPath $tmp -Destination $local -Force
      Log ("UPDATED "+$m.Path+" sha256="+$remoteSha)
      if($m.Local -eq "TT-Editorial-Tab-Watch.js"){$watcherUpdated=$true}
      if($m.Pattern){$restart+=$m}
    }

    foreach($m in $restart){
      StopMatch ([string]$m.Pattern)
      Start-Sleep -Milliseconds 500
      StartListener ([string]$m.Local)
    }
    # Node does not reload a JS script already in memory after an update.
    # Restart ONLY the editorial tab watcher daemon (not Chrome or listeners),
    # preserving its tracked-job JSON files on disk.
    if($watcherUpdated){
      $watcher=Join-Path $BaseDir "TT-Editorial-Tab-Watch.js"
      $old=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
        [string]$_.CommandLine -match "TT-Editorial-Tab-Watch[.]js" -and
        [string]$_.CommandLine -match "--daemon"
      })
      foreach($p in $old){
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Log ("TAB WATCHER UPDATED STOP pid="+$p.ProcessId) }
        catch { Log ("TAB WATCHER UPDATE DEFERRED pid="+$p.ProcessId+" "+$_.Exception.Message) }
      }
      $jobsDir=Join-Path $BaseDir "editorial-tab-watch"
      $pending=if(Test-Path -LiteralPath $jobsDir){@(Get-ChildItem -LiteralPath $jobsDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count}else{0}
      $stillRunning=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.CommandLine -match "TT-Editorial-Tab-Watch[.]js" -and [string]$_.CommandLine -match "--daemon"
      })
      if($pending -gt 0 -and $stillRunning.Count -eq 0){
        $p=Start-Process -FilePath (Get-Command node.exe -ErrorAction Stop).Source -ArgumentList @($watcher,"--daemon") -WindowStyle Hidden -PassThru -ErrorAction Stop
        Log ("TAB WATCHER UPDATED RESTART pid="+$p.Id+" tracked="+$pending)
      }
    }
    $ref=if($mainSha){$mainSha}else{"main"}
    Log ("CHECK OK raw-v7 ref="+$ref+" downloads="+$downloads+" restarts="+$restart.Count+" watcherUpdated="+$watcherUpdated)
  }catch{
    Log ("CHECK ERROR :: "+$_.Exception.Message)
  }
}

Log ("START raw-v6 interval="+$IntervalSeconds+" once="+$Once+" pid="+$PID)
do{
  CheckOnce
  if($Once){break}
  Start-Sleep -Seconds $IntervalSeconds
}while($true)
