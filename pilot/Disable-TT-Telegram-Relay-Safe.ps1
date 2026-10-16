#requires -Version 5.1
# Stop ONLY explicitly named TT Image Relay Telegram v2 scheduled task.
# Does not touch GitHub Actions, editorial listeners, Chrome, TTImages, SeLoRecordamos.
$ErrorActionPreference='Stop'
$Task='TT Image Relay - Telegram v2'
Write-Host '=== DETENER SOLO TT IMAGE RELAY - TELEGRAM V2 ===' -ForegroundColor Cyan
$t=Get-ScheduledTask -TaskName $Task -TaskPath '\' -ErrorAction Stop
if($t.TaskName -cne $Task -or $t.TaskPath -ne '\'){throw 'Nombre/ruta de tarea distintos; no se modifica nada.'}
$actionText=(@($t.Actions)|ForEach-Object{[string]$_.Execute+' '+[string]$_.Arguments}) -join ' '
if(!$actionText){throw 'Tarea sin acciones identificables; cancelado.'}
if($actionText -match '(?i)selorecordamos|TTImages[_\-]|TTImages_bot|TTImages/|TTImages\\'){
 throw 'La tarea parece contener una dependencia TTImages o SeLoRecordamos. No se detiene.'
}
if($actionText -notmatch '(?i)telegram|image.?relay|TTiTTulares|TTendencias|TT.?Image'){
 throw 'La tarea no parece un relay TT Telegram. No se detiene.'
}
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot\backups'
New-Item -ItemType Directory -Path $root -Force|Out-Null
$back=Join-Path $root ('TT-Image-Relay-Telegram-v2-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.xml')
$xml=Export-ScheduledTask -TaskName $Task -TaskPath '\'
# Saved for rollback. Don't display task XML: may contain private arguments.
[IO.File]::WriteAllText($back,$xml,([Text.UTF8Encoding]::new($false)))
Write-Host ('Copia para restaurar guardada en '+$back)
if([string]$t.State -eq 'Running'){
 Write-Host 'El relay exclusivo esta ejecutandose: se detiene SOLO esa tarea.'
 Stop-ScheduledTask -TaskName $Task -TaskPath '\' -ErrorAction Stop
}
Disable-ScheduledTask -TaskName $Task -TaskPath '\' -ErrorAction Stop|Out-Null
$final=Get-ScheduledTask -TaskName $Task -TaskPath '\' -ErrorAction Stop
if([string]$final.State -ne 'Disabled'){throw ('No se ha confirmado tarea deshabilitada: '+$final.State)}
Write-Host 'DESHABILITADA: TT Image Relay - Telegram v2.' -ForegroundColor Green
Write-Host 'CONSERVADAS: TT Image Relay - Botones v2, SeLoRecordamos, TTImages, listeners TT, Chrome.'
Write-Host 'NO se han desactivado los envios remotos de GitHub Actions: siguen sujetos a la separacion editorial.'
Write-Host 'Para revertir, si la tarea sigue presente:'
Write-Host '  Enable-ScheduledTask -TaskName "TT Image Relay - Telegram v2" -TaskPath "\"'
