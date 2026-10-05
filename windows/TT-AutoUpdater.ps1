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

function Log([string]$t){
  New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
  Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$t) -Encoding UTF8
}

function Get-MainSha{
  try{
    $doc=Invoke-RestMethod -Uri ("https://api.github.com/repos/fabricelop/europapress-rss/commits/main?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{
      "Accept"="application/vnd.github+json"
      "User-Agent"="TT-auto-updater-api-v5"
      "Cache-Control"="no-cache"
    } -TimeoutSec 20
    $sha=[string]$doc.sha
    if($sha -match '^[0-9a-f]{40}

function Sha256Bytes([byte[]]$b){
  $s=[Security.Cryptography.SHA256]::Create()
  try{([BitConverter]::ToString($s.ComputeHash($b))).Replace("-","").ToLowerInvariant()}
  finally{$s.Dispose()}
}

function LocalSha([string]$f){
  if(-not (Test-Path -LiteralPath $f)){return ""}
  Sha256Bytes ([IO.File]::ReadAllBytes($f))
}

function ValidatePs([string]$f){
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido: "+$e[0].Message}
}

function ValidateJs([string]$f){
  $n=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $n){$n=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $n){throw "Node no disponible"}
  $src=Get-Content -LiteralPath $f -Raw -Encoding UTF8
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    $src | & $n.Source --check - 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw "JS invalido: $f"}
}

function StopMatch([string]$p){
  if(-not $p){return}
  @(Get-CimInstance Win32_Process|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $p
  })|ForEach-Object{
    try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
  }
}

function StartListener([string]$name){
  $f=Join-Path $BaseDir $name
  $o=Join-Path $BaseDir ($name+".autoupdate.out.log")
  $e=Join-Path $BaseDir ($name+".autoupdate.err.log")
  $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$f) -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e -PassThru
  Start-Sleep -Milliseconds 900
  $p.Refresh()
  if($p.HasExited){throw "Listener no activo: $name"}
  Log ("RESTART OK "+$name+" pid="+$p.Id)
}

function CheckOnce{
  try{
    $restart=@()
    $downloads=0
    $mainSha=Get-MainSha
    foreach($m in $Managed){
      $local=Join-Path $BaseDir ([string]$m.Local)
      $bytes=Download-Raw ([string]$m.Path) $mainSha
      $downloads++
      if(-not $bytes -or $bytes.Length -lt 100){throw "Descarga vacia/corta: "+$m.Path}
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
    Log ("CHECK OK raw-v5 ref="+$(if($mainSha){$mainSha}else{"main"})+" downloads="+$downloads+" restarts="+$restart.Count)
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
){return $sha}
  }catch{
    Log ("MAIN SHA WARNING :: "+$_.Exception.Message)
  }
  return ""
}

function Download-Raw([string]$path,[string]$mainSha){
  $ref=if($mainSha){$mainSha}else{"main"}
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$ref+"/"+$path+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $wc=New-Object System.Net.WebClient
  try{
    $wc.Headers["User-Agent"]="TT-auto-updater-raw-v5"
    $wc.Headers["Cache-Control"]="no-cache"
    $bytes=$wc.DownloadData($url)
  }finally{$wc.Dispose()}
  if(-not $bytes -or $bytes.Length -lt 100){throw "RAW vacio/corto: $path ref=$ref"}
  return $bytes
}

function Sha256Bytes([byte[]]$b){
  $s=[Security.Cryptography.SHA256]::Create()
  try{([BitConverter]::ToString($s.ComputeHash($b))).Replace("-","").ToLowerInvariant()}
  finally{$s.Dispose()}
}

function LocalSha([string]$f){
  if(-not (Test-Path -LiteralPath $f)){return ""}
  Sha256Bytes ([IO.File]::ReadAllBytes($f))
}

function ValidatePs([string]$f){
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido: "+$e[0].Message}
}

function ValidateJs([string]$f){
  $n=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $n){$n=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $n){throw "Node no disponible"}
  $src=Get-Content -LiteralPath $f -Raw -Encoding UTF8
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    $src | & $n.Source --check - 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw "JS invalido: $f"}
}

function StopMatch([string]$p){
  if(-not $p){return}
  @(Get-CimInstance Win32_Process|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $p
  })|ForEach-Object{
    try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
  }
}

function StartListener([string]$name){
  $f=Join-Path $BaseDir $name
  $o=Join-Path $BaseDir ($name+".autoupdate.out.log")
  $e=Join-Path $BaseDir ($name+".autoupdate.err.log")
  $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$f) -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e -PassThru
  Start-Sleep -Milliseconds 900
  $p.Refresh()
  if($p.HasExited){throw "Listener no activo: $name"}
  Log ("RESTART OK "+$name+" pid="+$p.Id)
}

function CheckOnce{
  try{
    $restart=@()
    $downloads=0
    foreach($m in $Managed){
      $local=Join-Path $BaseDir ([string]$m.Local)
      $bytes=Download-Raw ([string]$m.Path)
      $downloads++
      if(-not $bytes -or $bytes.Length -lt 100){throw "Descarga vacia/corta: "+$m.Path}
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
    Log ("CHECK OK api-v4 downloads="+$downloads+" restarts="+$restart.Count)
  }catch{
    Log ("CHECK ERROR :: "+$_.Exception.Message)
  }
}

Log ("START api-v4 interval="+$IntervalSeconds+" once="+$Once+" pid="+$PID)
do{
  CheckOnce
  if($Once){break}
  Start-Sleep -Seconds $IntervalSeconds
}while($true)
