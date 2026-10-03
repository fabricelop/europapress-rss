param([int]$IntervalSeconds=600,[switch]$Once)
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$LogPath=Join-Path $BaseDir "tt-auto-updater.log"
$Managed=@(
  @{Path="windows/TTendenciasDedicatedListener.ps1";Local="TTendenciasDedicatedListener.ps1";Kind="ps";Pattern="*TTendenciasDedicatedListener.ps1*"},
  @{Path="windows/TTendenciasImageBridge.js";Local="TTendenciasImageBridge.js";Kind="js";Pattern=""},
  @{Path="windows/TTiTTularesDedicatedListener.ps1";Local="TTiTTularesDedicatedListener.ps1";Kind="ps";Pattern="*TTiTTularesDedicatedListener.ps1*"},
  @{Path="windows/TTiTTularesImageBridge.js";Local="TTiTTularesImageBridge.js";Kind="js";Pattern=""}
)
function Log([string]$t){New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null;Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$t) -Encoding UTF8}
function Api([string]$u){Invoke-RestMethod -Uri $u -Headers @{"Accept"="application/vnd.github+json";"User-Agent"="TT-auto-updater";"Cache-Control"="no-cache"} -TimeoutSec 20}
function Remote([string]$p){$u="https://api.github.com/repos/fabricelop/europapress-rss/contents/"+$p+"?ref=main&t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$d=Api $u;if(-not $d.content){throw "Sin contenido remoto: $p"};[Convert]::FromBase64String(([string]$d.content -replace "\s",""))}
function Hash([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($s.ComputeHash($b))).Replace("-","").ToLowerInvariant()}finally{$s.Dispose()}}
function ValidatePs([string]$f){$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)|Out-Null;if($e.Count -gt 0){throw "PowerShell invalido: "+$e[0].Message}}
function ValidateJs([string]$f){$n=Get-Command node.exe -ErrorAction SilentlyContinue;if(-not $n){$n=Get-Command node -ErrorAction SilentlyContinue};if(-not $n){throw "Node no disponible"};$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& $n.Source --check $f 1>$null 2>$null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};if($code -ne 0){throw "JS invalido: $f"}}
function StopMatch([string]$p){if(-not $p){return};@(Get-CimInstance Win32_Process|Where-Object{($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $p})|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}}
function StartListener([string]$name){$f=Join-Path $BaseDir $name;$o=Join-Path $BaseDir ($name+".autoupdate.out.log");$e=Join-Path $BaseDir ($name+".autoupdate.err.log");$p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$f) -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e -PassThru;Start-Sleep -Milliseconds 900;$p.Refresh();if($p.HasExited){throw "Listener no activo: $name"};Log ("RESTART OK "+$name+" pid="+$p.Id)}
function CheckOnce{
  try{
    $restart=@()
    foreach($m in $Managed){
      $bytes=Remote ([string]$m.Path)
      $local=Join-Path $BaseDir ([string]$m.Local)
      $rh=Hash $bytes
      $lh=""
      if(Test-Path -LiteralPath $local){$lh=Hash ([IO.File]::ReadAllBytes($local))}
      if($lh -eq $rh){continue}
      Log ("UPDATE "+$m.Path+" local="+$lh+" remote="+$rh)
      $tmp=$local+".autoupdate"+$(if($m.Kind -eq "js"){".new.js"}else{".new.ps1"})
      [IO.File]::WriteAllBytes($tmp,$bytes)
      if($m.Kind -eq "ps"){ValidatePs $tmp}else{ValidateJs $tmp}
      if((Hash ([IO.File]::ReadAllBytes($tmp))) -ne $rh){throw "Hash no coincide: "+$m.Path}
      Move-Item -LiteralPath $tmp -Destination $local -Force
      Log ("UPDATED "+$m.Path)
      if($m.Pattern){$restart+=$m}
    }
    foreach($m in $restart){StopMatch ([string]$m.Pattern);Start-Sleep -Milliseconds 500;StartListener ([string]$m.Local)}
    Log ("CHECK OK restarts="+$restart.Count)
  }catch{Log ("CHECK ERROR :: "+$_.Exception.Message)}
}
Log ("START interval="+$IntervalSeconds+" once="+$Once+" pid="+$PID)
do{CheckOnce;if($Once){break};Start-Sleep -Seconds $IntervalSeconds}while($true)
