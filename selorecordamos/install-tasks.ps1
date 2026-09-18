$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$listenerHidden = Join-Path $PSScriptRoot 'run-telegram-hidden.vbs'
$searchHidden = Join-Path $PSScriptRoot 'run-search-hidden.vbs'

if (-not (Test-Path $listenerHidden)) { throw "No existe $listenerHidden" }
if (-not (Test-Path $searchHidden)) { throw "No existe $searchHidden" }

$listenerTask = 'SeLoRecordamos-Telegram'
$searchTask = 'SeLoRecordamos-Search'
$wscript = "$env:SystemRoot\System32\wscript.exe"
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$listenerAction = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $listenerHidden + '"')
$searchAction = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $searchHidden + '"')
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# StartWhenAvailable recupera ejecuciones perdidas por PC apagado/suspension.
# Las opciones de bateria evitan que Windows silencie SLR en portatiles.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Write-Host 'Creando tarea del listener de Telegram...'
$listenerTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
Register-ScheduledTask -TaskName $listenerTask -Action $listenerAction -Trigger $listenerTrigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host 'Creando tarea de busqueda horaria robusta...'
# Un disparador al iniciar sesion hace que la busqueda se recupere inmediatamente
# tras encender el PC. El disparador diario mantiene las ejecuciones a los :05.
$searchLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$searchHourlyTrigger = New-ScheduledTaskTrigger -Daily -At '00:05'
$searchHourlyTrigger.Repetition.Interval = 'PT1H'
$searchHourlyTrigger.Repetition.Duration = 'P1D'
$searchHourlyTrigger.Repetition.StopAtDurationEnd = $false
Register-ScheduledTask -TaskName $searchTask -Action $searchAction -Trigger @($searchLogonTrigger, $searchHourlyTrigger) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host 'Arrancando listener ahora...'
Start-ScheduledTask -TaskName $listenerTask

Write-Host 'Ejecutando una busqueda ahora para validar y recuperar el periodo apagado...'
Start-ScheduledTask -TaskName $searchTask

Write-Host ''
Write-Host 'Tareas instaladas:' -ForegroundColor Green
Get-ScheduledTask -TaskName $listenerTask, $searchTask | ForEach-Object {
    $info = Get-ScheduledTaskInfo -TaskName $_.TaskName
    [PSCustomObject]@{
        TaskName = $_.TaskName
        State = $_.State
        LastRunTime = $info.LastRunTime
        LastTaskResult = $info.LastTaskResult
        NextRunTime = $info.NextRunTime
    }
} | Format-Table -AutoSize
Write-Host ''
Write-Host 'SeLoRecordamos queda configurado sin ventanas visibles.' -ForegroundColor Green
Write-Host 'La busqueda se ejecuta al iniciar sesion y cada hora a los :05; StartWhenAvailable recupera ejecuciones perdidas.'
