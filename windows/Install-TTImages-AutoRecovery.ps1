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
$pin='e40621093f166fff673a9d08935f199e0cb68f0f'
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
  $isOld=([string]$acts[0].Execute -match '(?i)powershell(\.exe)?$' -and [string]$acts[0].Arguments -like '*TTImages-AutoRecovery-Guardian.ps1*')
  $isNew=([string]$acts[0].Execute -match '(?i)wscript(\.exe)?$' -and [string]$acts[0].Arguments -like '*TTImages-AutoRecovery-Hidden.vbs*')
  if($acts.Count -ne 1 -or (-not $isOld -and -not $isNew)){
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
  # The guardian's SelfTest uses terminating 'throw' on any failure.
  # Never interpret its informational output: Windows PowerShell 5.1 may send
  # that output to the host instead of the capture pipeline.
  try {
    & (Join-Path $temp $names[0]) -SelfTest | Out-Null
  } catch {
    throw ('Pruebas automaticas del guardian fallidas: '+$_.Exception.Message)
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
  # WScript launches a hidden PowerShell host without a console flash.
  $launcher=Join-Path $dir 'TTImages-AutoRecovery-Hidden.vbs'
  $launcherText=@'
Option Explicit
Dim shell, fso, folder, guardian, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
guardian = fso.BuildPath(folder, "TTImages-AutoRecovery-Guardian.ps1")
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & guardian & """"
shell.Run command, 0, True
'@
  [IO.File]::WriteAllText($launcher,$launcherText,[Text.Encoding]::ASCII)
  $exe=Join-Path $env:SystemRoot 'System32\wscript.exe'
  $args='//B //Nologo "'+$launcher+'"'
  $action=New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $dir
  $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
  $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'TTImages: recupera visor 9234 tras 2 fallos consecutivos; no toca captura ni Telegram' -Force|Out-Null
  $saved=Get-ScheduledTask -TaskName $name -ErrorAction Stop
  if($saved.State -eq 'Disabled'){throw 'Tarea instalada pero deshabilitada'}
  $original=Get-ScheduledTask -TaskName $sourceTask -ErrorAction Stop
  Info ('GUARDIAN_INSTALADO estado='+$saved.State+' frecuencia=15min; invisible=wscript; recuperacion tras 2 fallos')
  Info ('CAPTURA_ORIGINAL_SIN_CAMBIOS estado='+$original.State)
  Info ('ARCHIVOS '+$dir)
  Info 'La próxima ejecución comprobará el estado; no toca galerías sanas ni reenviará imágenes'
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
