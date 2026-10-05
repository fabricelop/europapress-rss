param([int]$IntervalSeconds=120,[switch]$Once)
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$LogPath=Join-Path $BaseDir "tt-auto-updater.log"

$Managed=@(
  @{Path="windows/TTendenciasDedicatedListener.ps1";Local="TTendenciasDedicatedListener.ps1";Kind="ps";Pattern="*TTendenciasDedicatedListener.ps1*"},
  @{Path="windows/TTendenciasImageBridge.js";Local="TTendenciasImageBridge.js";Kind="js";Pattern=""},
  @{Path="windows/TTiTTularesDedicatedListener.ps1";Local="TTiTTularesDedicatedListener.ps1";Kind="ps";Pattern="*TTiTTularesDedicatedListener.ps1*"},
  @{Path="windows/TTiTTularesImageBridge.js";Local="TTiTTularesImageBridge.js";Kind="js";Pattern=""}
)

function Log([string]$Text){
  New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
  Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$Text) -Encoding UTF8
}

function Get-MainSha {
  try {
    $uri="https://api.github.com/repos/fabricelop/europapress-rss/commits/main?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $doc=Invoke-RestMethod -Uri $uri -Headers @{
      "Accept"="application/vnd.github+json"
      "User-Agent"="TT-auto-updater-api-v5"
      "Cache-Control"="no-cache"
    } -TimeoutSec 20
    $sha=[string]$doc.sha
    if($sha -match "^[0-9a-fA-F]{40}$"){return $sha.ToLowerInvariant()}
  } catch {
    Log ("MAIN SHA WARNING :: "+$_.Exception.Message)
  }
  return ""
}

function Download-Raw([string]$Path,[string]$MainSha){
  $ref=if($MainSha){$MainSha}else{"main"}
  $uri="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$ref+"/"+$Path+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $wc=New-Object System.Net.WebClient
  try{
    $wc.Headers["User-Agent"]="TT-auto-updater-raw-v5"
    $wc.Headers["Cache-Control"]="no-cache"
    $bytes=$wc.DownloadData($uri)
  }finally{
    $wc.Dispose()
  }
  if(-not $bytes -or $bytes.Length -lt 100){throw "RAW vacio/corto: $Path ref=$ref"}
  return $bytes
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
    $downloads=0
    $mainSha=Get-MainSha
    foreach($m in $Managed){
      $local=Join-Path $BaseDir ([string]$m.Local)
      $bytes=Download-Raw ([string]$m.Path) $mainSha
      $downloads++
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
      if($m.Pattern){$restart+=$m}
    }

    foreach($m in $restart){
      StopMatch ([string]$m.Pattern)
      Start-Sleep -Milliseconds 500
      StartListener ([string]$m.Local)
    }
    $ref=if($mainSha){$mainSha}else{"main"}
    Log ("CHECK OK raw-v5 ref="+$ref+" downloads="+$downloads+" restarts="+$restart.Count)
  }catch{
    Log ("CHECK ERROR :: "+$_.Exception.Message)
  }
}

Log ("START raw-v5 interval="+$IntervalSeconds+" once="+$Once+" pid="+$PID)
do{
  CheckOnce
  if($Once){break}
  Start-Sleep -Seconds $IntervalSeconds
}while($true)
