$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$listenerScript = Join-Path $PSScriptRoot 'run-telegram-listener.ps1'
$searchScript = Join-Path $PSScriptRoot 'run-search.ps1'

if (-not (Test-Path $listenerScript)) { throw "No existe $listenerScript" }
if (-not (Test-Path $searchScript)) { throw "No existe $searchScript" }

$listenerTask = 'SeLoRecordamos-Telegram'
$searchTask = 'SeLoRecordamos-Search'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$listenerCmd = '"' + $ps + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $listenerScript + '"'
$searchCmd = '"' + $ps + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $searchScript + '"'

Write-Host 'Creando tarea del listener de Telegram...'
& schtasks.exe /Create /TN $listenerTask /TR $listenerCmd /SC ONLOGON /RL LIMITED /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo crear $listenerTask" }

Write-Host 'Creando tarea de búsqueda horaria...'
& schtasks.exe /Create /TN $searchTask /TR $searchCmd /SC HOURLY /MO 1 /ST 00:05 /RL LIMITED /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo crear $searchTask" }

Write-Host 'Arrancando listener ahora...'
& schtasks.exe /Run /TN $listenerTask | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No se pudo arrancar $listenerTask" }

Write-Host ''
Write-Host 'Tareas instaladas:' -ForegroundColor Green
& schtasks.exe /Query /TN $listenerTask /FO LIST /V | Select-String 'TaskName|Status|Next Run Time|Nombre de tarea|Estado|Próxima hora de ejecución' | Out-Host
& schtasks.exe /Query /TN $searchTask /FO LIST /V | Select-String 'TaskName|Status|Next Run Time|Nombre de tarea|Estado|Próxima hora de ejecución' | Out-Host
Write-Host ''
Write-Host 'SeLoRecordamos queda configurado sin ventanas visibles.' -ForegroundColor Green
Write-Host 'La búsqueda se ejecuta cada hora a los :05 y el listener arranca al iniciar sesión.'
