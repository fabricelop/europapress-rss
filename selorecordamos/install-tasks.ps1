$ErrorActionPreference = 'Stop'

$listenerHidden = Join-Path $PSScriptRoot 'run-telegram-hidden.vbs'
$searchHidden = Join-Path $PSScriptRoot 'run-search-hidden.vbs'
$publishedHidden = Join-Path $PSScriptRoot 'run-published-hidden.vbs'
$watchdogHidden = Join-Path $PSScriptRoot 'run-watchdog-hidden.vbs'

foreach ($file in @($listenerHidden, $searchHidden, $publishedHidden, $watchdogHidden)) {
    if (-not (Test-Path $file)) { throw "No existe $file" }
}

$listenerTask = 'SeLoRecordamos-Telegram'
$searchTask = 'SeLoRecordamos-Search'
$publishedTask = 'SeLoRecordamos-Published'
$watchdogTask = 'SeLoRecordamos-Watchdog'

$wscript = "$env:SystemRoot\System32\wscript.exe"
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

function Install-RepeatingTask {
    param(
        [string]$Name,
        [string]$HiddenScript,
        [ValidateSet('HOURLY','MINUTE')][string]$Schedule,
        [int]$Modifier,
        [string]$StartTime,
        [bool]$AtLogon
    )

    $cmd = '"' + $wscript + '" "' + $HiddenScript + '"'
    & schtasks.exe /Create /TN $Name /TR $cmd /SC $Schedule /MO $Modifier /ST $StartTime /RL LIMITED /F | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear $Name" }

    Set-ScheduledTask -TaskName $Name -Settings $settings | Out-Null

    if ($AtLogon) {
        $existingTriggers = @((Get-ScheduledTask -TaskName $Name).Triggers)
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        Set-ScheduledTask -TaskName $Name -Trigger @($existingTriggers + $logonTrigger) | Out-Null
    }
}

Write-Host 'Creando listener Telegram...'
$listenerAction = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $listenerHidden + '"')
$listenerTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
Register-ScheduledTask -TaskName $listenerTask -Action $listenerAction -Trigger $listenerTrigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host 'Creando busqueda horaria a los :05...'
Install-RepeatingTask -Name $searchTask -HiddenScript $searchHidden -Schedule HOURLY -Modifier 1 -StartTime '00:05' -AtLogon $true

Write-Host 'Creando importacion de historico a los :20...'
Install-RepeatingTask -Name $publishedTask -HiddenScript $publishedHidden -Schedule HOURLY -Modifier 1 -StartTime '00:20' -AtLogon $true

Write-Host 'Creando watchdog cada 15 minutos...'
Install-RepeatingTask -Name $watchdogTask -HiddenScript $watchdogHidden -Schedule MINUTE -Modifier 15 -StartTime '00:02' -AtLogon $true

Write-Host 'Arrancando listener...'
Start-ScheduledTask -TaskName $listenerTask

Write-Host 'Ejecutando busqueda e historico ahora para recuperar el hueco pendiente...'
Start-ScheduledTask -TaskName $searchTask
Start-ScheduledTask -TaskName $publishedTask

Write-Host 'Ejecutando watchdog...'
Start-ScheduledTask -TaskName $watchdogTask

Start-Sleep -Seconds 2

Write-Host ''
Write-Host 'Tareas SeLoRecordamos:' -ForegroundColor Green
Get-ScheduledTask -TaskName $listenerTask, $searchTask, $publishedTask, $watchdogTask | ForEach-Object {
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
Write-Host 'Busqueda: cada hora :05. Historico: cada hora :20. Watchdog: cada 15 min. Listener: continuo desde inicio de sesion.'
