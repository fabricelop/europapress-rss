#requires -Version 5.1
<#
TTImages automatic viewer recovery installer.
Adds one SEPARATE scheduled guardian without changing the existing
TT Image Relay - Telegram v2 or Botones v2 task, capture code, baseline,
images, bot token, Chrome session or its tasks.
#>
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
$dir=Join-Path $root 'AutoRecovery-v1'
$name='TTImages - AutoRecovery Viewer'
$sourceTask='TT Image Relay - Telegram v2'
$pin='d52c824524c1f857a1aac110d1e69f8bf8dac500'
$base='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'
$names=@('TTImages-AutoRecovery-Guardian.ps1','Recuperar-TTImages-Visor-Bloqueado.ps1')
function Info([string]$m){Write-Host ('TTIMAGES_INSTALL '+$m)}
Info ('INICIO '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if(-not(Test-Path -LiteralPath $root)){throw 'No se ha encontrado TTImageRelay. Sin cambios.'}
if(-not(Test-Path -LiteralPath (Join-Path $root 'informe-captura-v2.json'))){
  throw 'No se ha encontrado informe-captura-v2.json. Sin cambios.'
}
$existing=Get-ScheduledTask -TaskName $sourceTask -ErrorAction Stop
if($existing.State -eq 'Disabled'){throw 'La tarea de captura está deshabilitada; no instalar sin revisarla.'}
# Validate independent Chrome only. No navigation/changes to any target.
$chrome=Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/version' -TimeoutSec 7
if([string]$chrome.Browser -notmatch '^Chrome/'){throw 'Chrome independiente 9234 no disponible; sin cambios'}
$owned=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($owned){
  $acts=@($owned.Actions)
  if($acts.Count -ne 1 -or [string]$acts[0].Execute -notmatch '(?i)powershell(\.exe)?$' -or
     [string]$acts[0].Arguments -notlike '*TTImages-AutoRecovery-Guardian.ps1*'){
    throw 'Existe una tarea con el mismo nombre que no pertenece a este instalador. Sin cambios.'
  }
}
$temp=Join-Path $env:TEMP ('TTImages-Guardian-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force|Out-Null
try {
  foreach($fileName in $names){
    $destination=Join-Path $temp $fileName
    Invoke-WebRequest -UseBasicParsing -Uri ($base+$fileName) -OutFile $destination -TimeoutSec 45
    $src=[IO.File]::ReadAllText($destination,[Text.Encoding]::UTF8)
    if($src.Length -lt 4000 -or -not $src.Contains('#requires -Version 5.1')){
      throw ('Fichero incompleto: '+$fileName)
    }
    $tokens=$null;$parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile($destination,[ref]$tokens,[ref]$parseErrors)|Out-Null
    if($parseErrors.Count){throw ('Error PowerShell '+$fileName+': '+($parseErrors[0].Message))}
  }
  $guardCode=[IO.File]::ReadAllText((Join-Path $temp $names[0]),[Text.Encoding]::UTF8)
  $recoverCode=[IO.File]::ReadAllText((Join-Path $temp $names[1]),[Text.Encoding]::UTF8)
  foreach($marker in @('Test-RepeatedBlock','auto-recovery-v1-state.json','RECOVERY_ATTEMPT','-NoTaskStart','30')){
    if(-not $guardCode.Contains($marker)){throw ('Guardian incompleto: '+$marker)}
  }
  foreach($marker in @('GetChromeTargets','GALERIA_NUEVA_CONFIRMADA','RECUPERACION_HTTP_OK')){
    if(-not $recoverCode.Contains($marker)){throw ('Recuperador incompleto: '+$marker)}
  }
  $testOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp $names[0]) -SelfTest 2>&1
  if($LASTEXITCODE -ne 0 -or -not (($testOutput|Out-String).Contains('TTIMAGES_AUTORECOVERY_SELFTEST_OK'))){
    throw ('Pruebas automáticas del guardián fallidas: '+($testOutput|Out-String))
  }
  Info 'VALIDADO versiones, Chrome 9234, sintaxis de ambos scripts y pruebas de detección'
  if($PreflightOnly){
    Info 'PREFLIGHT_OK no se ha instalado ni modificado ninguna tarea'
    return
  }
  if(-not(Test-Path -LiteralPath $dir)){
    New-Item -ItemType Directory -Path $dir -Force|Out-Null
  }
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach($fileName in $names){
    $destination=Join-Path $dir $fileName
    if(Test-Path -LiteralPath $destination){
      Copy-Item -LiteralPath $destination -Destination ($destination+'.before-'+$stamp+'.bak') -Force
    }
    Copy-Item -LiteralPath (Join-Path $temp $fileName) -Destination $destination -Force
  }
  $guardian=Join-Path $dir $names[0]
  $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$guardian+'"'
  $action=New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $dir
  $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'TTImages: recupera visor 9234 tras 2 fallos consecutivos; no toca captura ni Telegram' -Force|Out-Null
  $saved=Get-ScheduledTask -TaskName $name -ErrorAction Stop
  if($saved.State -eq 'Disabled'){throw 'Tarea instalada pero deshabilitada'}
  $original=Get-ScheduledTask -TaskName $sourceTask -ErrorAction Stop
  Info ('GUARDIAN_INSTALADO estado='+$saved.State+' frecuencia=5min; recuperación tras 2 fallos')
  Info ('CAPTURA_ORIGINAL_SIN_CAMBIOS estado='+$original.State)
  Info ('ARCHIVOS '+$dir)
  Info 'La próxima ejecución comprobará el estado; no toca galerías sanas ni reenviará imágenes'
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
