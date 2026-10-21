# Install-TTiTTulares-Listener-v52.ps1
# Recovery dirigida: restaura bridge TTiTTulares v52 single-insert, limpia solo el bridge/job local atascado
# y arranca una unica instancia. No reinicia Chrome 9223 ni mata procesos TTendencias.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="7133aae20293940585f1c71e103f81a9dcccf0f6"
$Listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Bridge=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$Watchdog=Join-Path $BaseDir "TT-LocalWatchdog.ps1"
$Updater=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$State=Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$Lock=Join-Path $BaseDir "ttittulares-image-bridge.lock.json"
$Log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"

$TmpListener=$Listener+".v52.new"
$TmpBridge=Join-Path $BaseDir "TTiTTularesImageBridge.v52.new.js"
$TmpWatchdog=$Watchdog+".v8.new"

function Get-PsProc([string]$Pattern){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and [string]$_.CommandLine -like $Pattern
  })
}
function Stop-Rows($Rows){
  @($Rows)|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
}
function Show-State([string]$Label){
  Write-Host ""
  Write-Host ("--- "+$Label+" ---") -ForegroundColor Cyan
  $ls=@(Get-PsProc "*TTiTTularesDedicatedListener.ps1*")
  Write-Host ("Listeners: "+$(if($ls.Count){($ls.ProcessId -join ", ")}else{"ninguno"}))
  if(Test-Path $State){
    try{
      $s=Get-Content $State -Raw -Encoding UTF8|ConvertFrom-Json
      Write-Host ("active_image_commands: "+((@($s.active_image_commands)|ForEach-Object{[string]$_}) -join ", "))
      Write-Host ("seen_count: "+@($s.image_commands).Count)
    }catch{Write-Host ("State ERROR: "+$_.Exception.Message)}
  }
  if(Test-Path $Lock){
    try{
      $l=Get-Content $Lock -Raw -Encoding UTF8|ConvertFrom-Json
      $pidv=[int]$l.pid
      $p=if($pidv -gt 0){Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidv) -ErrorAction SilentlyContinue}else{$null}
      $isTT=($p -and [string]$p.CommandLine -like "*TTiTTularesImageBridge.js*")
      Write-Host ("Lock: command="+[string]$l.command_id+" target="+[string]$l.target_id+" pid="+$pidv+" live_tt_bridge="+[int][bool]$isTT+" started_at="+[string]$l.started_at)
    }catch{Write-Host ("Lock ERROR: "+$_.Exception.Message)}
  }else{Write-Host "Lock: no existe"}
}

New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
Show-State "ANTES"

$headers=@{
  "User-Agent"="TTiTTulares-v52-installer"
  "Cache-Control"="no-cache, no-store"
  "Pragma"="no-cache"
}

Invoke-WebRequest -Uri ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TTiTTularesDedicatedListener.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $TmpListener -UseBasicParsing -Headers $headers -TimeoutSec 30
Invoke-WebRequest -Uri ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TTiTTularesImageBridge.js?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $TmpBridge -UseBasicParsing -Headers $headers -TimeoutSec 30
Invoke-WebRequest -Uri ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TT-LocalWatchdog.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $TmpWatchdog -UseBasicParsing -Headers $headers -TimeoutSec 30

$lt=Get-Content $TmpListener -Raw -Encoding UTF8
$bt=Get-Content $TmpBridge -Raw -Encoding UTF8
$wt=Get-Content $TmpWatchdog -Raw -Encoding UTF8
if(-not $lt.Contains('$WorkerId = "ttittulares-dedicated-v52"')){throw "Listener descargado no es v52"}
if(-not $lt.Contains('BRIDGE_FEATURES="v28-reject-nonconversation-image-targets"')){throw "Listener v52 no valida bridge v52 single-insert"}
if(-not $lt.Contains('IMAGE GLOBAL SLOT WAIT project=ttendencias')){throw "Listener v52 no respeta slot global"}
if(-not $lt.Contains('IMAGE ACTIVE ORPHAN GRACE')){throw "Listener v52 no contiene gracia anti-cascada"}
if(-not $bt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){throw "Bridge descargado no es familia v28"}
if(-not $bt.Contains('BRIDGE_FEATURES="v28-reject-nonconversation-image-targets"')){throw "Bridge descargado no es el v52 single-insert"}
if(-not $bt.Contains('await cdp.call("Input.insertText",{text:message});')){throw "Bridge descargado no usa single Input.insertText"}
if(-not $bt.Contains('ttittulares-image-bridge-v28-dead-submit-retry')){throw "Worker del bridge no es v52 single-insert"}
if($bt.Contains('v29-visible-composer-trusted-click-dom-fallback')){throw "Bridge descargado contiene v29 no deseado"}
if(-not $wt.Contains('watchdog-restart-refresh-v8-ttittulares-no-queue-restart')){throw "Watchdog descargado no es v8"}

foreach($f in @($TmpListener,$TmpWatchdog)){
  $tokens=$null;$errors=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){throw ("PowerShell invalido en "+$f+": "+(($errors|ForEach-Object{$_.Message}) -join " | "))}
}
$node=Get-Command node.exe -ErrorAction SilentlyContinue
if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
if(-not $node){throw "Node no disponible"}
& $node.Source --check $TmpBridge
if($LASTEXITCODE -ne 0){throw "bridge v52 descargado no pasa node --check"}

# Congelar solo los procesos de supervision durante unos segundos para evitar carreras.
$oldUpdater=@(Get-PsProc "*TT-AutoUpdater.ps1*")
$oldWatchdog=@(Get-PsProc "*TT-LocalWatchdog.ps1*")
Stop-Rows $oldUpdater
Stop-Rows $oldWatchdog
Stop-Rows @(Get-PsProc "*TTiTTularesDedicatedListener.ps1*")
Start-Sleep -Milliseconds 700

# Matar UNICAMENTE el bridge TTiTTulares del lock actual, nunca TTendencias.
$lockedCommand=""
if(Test-Path $Lock){
  try{
    $l=Get-Content $Lock -Raw -Encoding UTF8|ConvertFrom-Json
    $lockedCommand=[string]$l.command_id
    $pidv=[int]$l.pid
    if($pidv -gt 0){
      $p=Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidv) -ErrorAction SilentlyContinue
      if($p -and [string]$p.CommandLine -like "*TTiTTularesImageBridge.js*"){
        Write-Host ("Deteniendo bridge TTiTTulares atascado PID "+$pidv+" command="+$lockedCommand) -ForegroundColor Yellow
        Stop-Process -Id $pidv -Force -ErrorAction SilentlyContinue
      }
    }
  }catch{Write-Host ("AVISO lock: "+$_.Exception.Message) -ForegroundColor Yellow}
}

# Limpiar solo el command activo asociado al lock retirado. Conservar historial seen.
if($lockedCommand -and (Test-Path $State)){
  try{
    $s=Get-Content $State -Raw -Encoding UTF8|ConvertFrom-Json
    $s.active_image_commands=@(@($s.active_image_commands)|Where-Object{[string]$_ -ne $lockedCommand}|Select-Object -Unique)
    $s|ConvertTo-Json -Depth 12|Set-Content $State -Encoding UTF8
    Write-Host ("Active local retirado: "+$lockedCommand)
  }catch{Write-Host ("AVISO state: "+$_.Exception.Message) -ForegroundColor Yellow}
}
Remove-Item $Lock -Force -ErrorAction SilentlyContinue

Move-Item $TmpListener $Listener -Force
Move-Item $TmpBridge $Bridge -Force
Move-Item $TmpWatchdog $Watchdog -Force

$ps=Get-Command powershell.exe -ErrorAction SilentlyContinue
if(-not $ps){throw "powershell.exe no disponible"}

# Arrancar en orden: listener -> watchdog -> updater. TTendencias sigue intacto.
$lp=Start-Process $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
$lp.Refresh()
if($lp.HasExited){throw "Listener v52 termino al arrancar. ExitCode=$($lp.ExitCode)"}

$wp=Start-Process $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Watchdog) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 1
$wp.Refresh()
if($wp.HasExited){throw "Watchdog v8 termino al arrancar. ExitCode=$($wp.ExitCode)"}

$up=$null
if(Test-Path $Updater){
  $up=Start-Process $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Updater) -WindowStyle Hidden -PassThru
}

# Deduplicar tras posibles carreras de arranque, conservando el listener v52 recién creado.
Start-Sleep -Seconds 4
$ls=@(Get-PsProc "*TTiTTularesDedicatedListener.ps1*")
foreach($x in $ls){
  if($x.ProcessId -ne $lp.Id){try{Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
}
Start-Sleep -Seconds 12

Write-Host ""
Write-Host "TTITTULARES v52 / BRIDGE v52 SINGLE-INSERT INSTALADOS" -ForegroundColor Green
Write-Host ("PID listener esperado: "+$lp.Id)
Write-Host ("PID watchdog v8: "+$wp.Id)
if($up){Write-Host ("PID auto-updater: "+$up.Id)}
Write-Host "Chrome 9223: NO reiniciado"
Write-Host "TTendencias: procesos y bridge NO detenidos"
Show-State "DESPUES"

Write-Host ""
Write-Host "Ultimas lineas TTiTTulares:"
if(Test-Path $Log){Get-Content $Log -Tail 45}
