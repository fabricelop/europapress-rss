# Repair-TTiTTulares-Listener.ps1
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

function Get-GitHubFile([string]$remote,[string]$dest,[string]$kind="ps"){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"+$remote+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $tmp=$dest+$(if($kind -eq "js"){".repair.new.js"}else{".repair.new.ps1"})
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -Headers @{
    "User-Agent"="TTiTTulares-listener-repair-raw-v2"
    "Cache-Control"="no-cache, no-store"
    "Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -lt 100){
    throw "RAW vacío/corto: $remote"
  }
  if($kind -eq "js"){
    $node=Get-Command node.exe -ErrorAction SilentlyContinue
    if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
    if(-not $node){throw "Node no disponible para validar $remote"}
    $old=$ErrorActionPreference
    try{
      $ErrorActionPreference="Continue"
      & $node.Source --check $tmp 1>$null 2>$null
      $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$old}
    if($code -ne 0){throw "JavaScript invalido en $remote"}
  }else{
    $t=$null;$e=$null
    [Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$t,[ref]$e)|Out-Null
    if($e.Count -gt 0){throw "PowerShell invalido en $remote :: "+$e[0].Message}
  }
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}


$listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$trendListener=Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$watchdog=Join-Path $BaseDir "TT-LocalWatchdog.ps1"
$updater=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$ttBridge=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$trBridge=Join-Path $BaseDir "TTendenciasImageBridge.js"
Get-GitHubFile "windows/TTiTTularesDedicatedListener.ps1" $listener "ps"
Get-GitHubFile "windows/TTendenciasDedicatedListener.ps1" $trendListener "ps"
Get-GitHubFile "windows/TT-LocalWatchdog.ps1" $watchdog "ps"
Get-GitHubFile "windows/TT-AutoUpdater.ps1" $updater "ps"
Get-GitHubFile "windows/TTiTTularesImageBridge.js" $ttBridge "js"
Get-GitHubFile "windows/TTendenciasImageBridge.js" $trBridge "js"

$listenerText=Get-Content -LiteralPath $listener -Raw -Encoding UTF8
if($listenerText -notmatch 'ttittulares-dedicated-v44'){throw "Se descargó un listener anterior; se esperaba v44"}
$bridgeText=Get-Content -LiteralPath $ttBridge -Raw -Encoding UTF8
if($bridgeText -notmatch 'ttittulares-image-bridge-v32-strict-submit'){throw "Se descargó un bridge anterior; se esperaba v32"}

foreach($pat in @("*TTiTTularesDedicatedListener.ps1*","*TTendenciasDedicatedListener.ps1*","*TT-LocalWatchdog.ps1*","*TT-AutoUpdater.ps1*")){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $pat
  }) | ForEach-Object {
    try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
  }
}
Start-Sleep -Milliseconds 700

# El listener antiguo pudo marcar localmente un trigger como consumido tras un 409
# aunque el ack remoto nunca se persistiera. Reseteamos solo el cursor editorial.
$statePath=Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
if(Test-Path $statePath){
  try{
    $s=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($s.PSObject.Properties.Name -contains "last_command_id"){$s.last_command_id=""}
    if($s.PSObject.Properties.Name -contains "conflict_command_id"){$s.conflict_command_id=""}
    if($s.PSObject.Properties.Name -contains "conflict_first_at"){$s.conflict_first_at=""}
    if($s.PSObject.Properties.Name -contains "active_image_commands"){$s.active_image_commands=@()}
    # image_commands se conserva: el listener v38 vuelve a intentar REQUESTED
    # actuales aunque el command_id ya aparezca en el historial local.
    $s | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
  }catch{}
}

# Limpiar bridges/locks huérfanos dejados por Chrome OOM.
foreach($lockName in @("ttittulares-image-bridge.lock.json","ttendencias-image-bridge.lock.json")){
  $lockPath=Join-Path $BaseDir $lockName
  if(Test-Path -LiteralPath $lockPath){
    try{
      $lock=Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $bridgePid=[int]$lock.pid
      if($bridgePid -gt 0){
        try{Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue}catch{}
      }
    }catch{}
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -ieq "node.exe" -and (
    [string]$_.CommandLine -like "*TTiTTularesImageBridge.js*" -or
    [string]$_.CommandLine -like "*TTendenciasImageBridge.js*"
  )
}) | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{} }

function Start-Hidden([string]$file,[string]$name){
  $out=Join-Path $BaseDir ($name+".repair.out.log")
  $err=Join-Path $BaseDir ($name+".repair.err.log")
  Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
  $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$file) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  Start-Sleep -Seconds 2
  $p.Refresh()
  if($p.HasExited){
    # Un segundo arranque de un listener singleton puede salir porque otra
    # instancia válida ya ganó la carrera. Verificar antes de declarar fallo.
    $base=[IO.Path]::GetFileName($file)
    $live=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
      [string]$_.CommandLine -like ("*"+$base+"*")
    })
    if($live.Count -gt 0){
      return [pscustomobject]@{Id=[int]$live[0].ProcessId}
    }
    Write-Host ("ARRANQUE FALLIDO "+$name+" ExitCode="+$p.ExitCode) -ForegroundColor Red
    if(Test-Path $err){Write-Host "--- stderr ---";Get-Content $err -Tail 40}
    if(Test-Path $out){Write-Host "--- stdout ---";Get-Content $out -Tail 40}
    if($name -eq "ttittulares-listener"){
      $diag=Join-Path $BaseDir "ttittulares-mobile-trigger.log"
      if(Test-Path $diag){Write-Host "--- listener log ---";Get-Content $diag -Tail 40}
    }
    throw "$name no quedo activo"
  }
  return $p
}

# Arrancar primero los listeners para evitar una carrera con el watchdog:
# si el watchdog arranca antes, puede crear el listener y hacer que el segundo
# proceso salga por el mutex singleton, pareciendo falsamente un fallo.
$l=Start-Hidden $listener "ttittulares-listener"
$tl=Start-Hidden $trendListener "ttendencias-listener"
$u=Start-Hidden $updater "tt-auto-updater"
$w=Start-Hidden $watchdog "tt-local-watchdog"
Start-Sleep -Seconds 5

$count=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*"
}).Count
$tcount=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TTendenciasDedicatedListener.ps1*"
}).Count

Write-Host "TT automation reparada: listener v44 + bridges v32 + watchdog + updater" -ForegroundColor Green
Write-Host ("TTiTTulares listeners activos: "+$count)
Write-Host ("TTendencias listeners activos: "+$tcount)
Write-Host ("PID TTiTTulares: "+$l.Id)
Write-Host ("PID TTendencias: "+$tl.Id)
Write-Host ("PID watchdog: "+$w.Id)
Write-Host ("PID updater: "+$u.Id)
$log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"
if(Test-Path $log){
  Write-Host ""
  Write-Host "Ultimas lineas:" -ForegroundColor Cyan
  Get-Content $log -Tail 20
}
