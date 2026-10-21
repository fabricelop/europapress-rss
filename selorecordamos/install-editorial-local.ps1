# Instala la tarea SLR sin Ollama, usando el lanzador de navegador TT.
$ErrorActionPreference='Stop'
$runner=Join-Path $PSScriptRoot 'run-editorial-local.ps1'
$hidden=Join-Path $PSScriptRoot 'run-editorial-hidden.vbs'
$task='SeLoRecordamos-Editorial-Local'
if (-not (Test-Path $runner)) { throw 'Falta run-editorial-local.ps1' }
if (-not (Test-Path $hidden)) { throw 'Falta run-editorial-hidden.vbs' }
if (-not (Test-Path 'C:\TTiTTulares\Ejecutar.js')) { throw 'Falta el lanzador existente C:\TTiTTulares\Ejecutar.js' }
$js=Get-Content 'C:\TTiTTulares\Ejecutar.js' -Raw -Encoding UTF8
if (-not $js.Contains('TT_CHAT_MESSAGE_B64') -or -not $js.Contains('--enviar')) { throw 'El lanzador TT no soporta el mensaje personalizado requerido' }
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { throw 'Node.js no encontrado' }
if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) { throw 'Python no encontrado' }
# wscript.exe + Run(..., 0, True) evita cualquier ventana al ejecutar con el Programador.
$wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
$action=New-ScheduledTaskAction -Execute $wscript -Argument ('"'+$hidden+'"')
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
$actual = Get-ScheduledTask -TaskName $task
if ([IO.Path]::GetFileName([string]$actual.Actions.Execute) -ine 'wscript.exe') { throw 'La tarea no se instaló con wscript.exe' }
Write-Host "Tarea $task instalada sin ventanas (cada 15 minutos)."
Write-Host "Ejecutable: $($actual.Actions.Execute)"
Write-Host "Argumentos: $($actual.Actions.Arguments)"
Write-Host "Registro: selorecordamos/runtime/editorial-local.log"
Write-Host "La tarea utiliza ChatGPT (lanzador compartido TT), no Ollama."
