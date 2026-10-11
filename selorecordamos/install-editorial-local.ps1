# Instala la tarea SLR sin Ollama, usando el lanzador de navegador TT.
$ErrorActionPreference='Stop'
$runner=Join-Path $PSScriptRoot 'run-editorial-local.ps1'
$task='SeLoRecordamos-Editorial-Local'
if (-not (Test-Path $runner)) { throw 'Falta run-editorial-local.ps1' }
if (-not (Test-Path 'C:\TTiTTulares\Ejecutar.js')) { throw 'Falta el lanzador existente C:\TTiTTulares\Ejecutar.js' }
$js=Get-Content 'C:\TTiTTulares\Ejecutar.js' -Raw -Encoding UTF8
if (-not $js.Contains('TT_CHAT_MESSAGE_B64') -or -not $js.Contains('--enviar')) { throw 'El lanzador TT no soporta el mensaje personalizado requerido' }
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { throw 'Node.js no encontrado' }
if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) { throw 'Python no encontrado' }
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runner+'"')
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
Write-Host "Tarea $task instalada (cada 15 minutos). Revisar el log selorecordamos/runtime/editorial-local.log. El lanzador usa temporalmente el chat TT para entregar instrucciones SLR."
