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

# Limpieza de ejecuciones antiguas de SLR. Las versiones anteriores del lanzador
# oculto podían dejar procesos desacoplados del Programador de tareas.
$legacyTask = 'SeLoRecordamos-Historico'
$slrTaskNames = @($listenerTask, $searchTask, $publishedTask, $watchdogTask, $legacyTask)
foreach ($name in $slrTaskNames) {
    try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } catch {}
}
try {
    if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false
        Write-Host 'Tarea antigua SeLoRecordamos-Historico eliminada.'
    }
} catch {}

$slrProcessPatterns = @(
    'selorecordamos\run-telegram-listener.ps1',
    'selorecordamos\run-search.ps1',
    'selorecordamos\run-published-import.ps1',
    'selorecordamos\watchdog.ps1',
    'selorecordamos\run-telegram-hidden.vbs',
    'selorecordamos\run-search-hidden.vbs',
    'selorecordamos\run-published-hidden.vbs',
    'selorecordamos\run-watchdog-hidden.vbs',
    'selorecordamos\telegram_local.js',
    'selorecordamos\search_x.js',
    'selorecordamos\publish_search_report.js',
    'selorecordamos\import_published.js',
    'selorecordamos\postprocess_search.js'
)

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = [string]$_.CommandLine
    if ($cmd) {
        foreach ($pattern in $slrProcessPatterns) {
            if ($cmd -like "*$pattern*") {
                try {
                    Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null
                    Write-Host ("Proceso SLR antiguo detenido: PID " + $_.ProcessId)
                } catch {}
                break
            }
        }
    }
}

Start-Sleep -Seconds 1

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

Write-Host 'Ejecutando busqueda ahora para recuperar el hueco pendiente...'
Start-ScheduledTask -TaskName $searchTask

Write-Host 'Esperando a que termine Search antes de arrancar Published para evitar colisiones Git...'
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 2
    $searchState = (Get-ScheduledTask -TaskName $searchTask).State
} while ($searchState -eq 'Running' -and (Get-Date) -lt $deadline)

if ($searchState -eq 'Running') {
    Write-Warning 'Search sigue ejecutandose tras 3 minutos; Published se deja para su proximo :20 para no colisionar.'
} else {
    $searchInfo = Get-ScheduledTaskInfo -TaskName $searchTask
    Write-Host ("Search termino. LastTaskResult=" + $searchInfo.LastTaskResult)
    Write-Host 'Ejecutando historico ahora...'
    Start-ScheduledTask -TaskName $publishedTask

    $publishedDeadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        $publishedState = (Get-ScheduledTask -TaskName $publishedTask).State
    } while ($publishedState -eq 'Running' -and (Get-Date) -lt $publishedDeadline)

    if ($publishedState -eq 'Running') {
        Write-Warning 'Published sigue ejecutandose tras 3 minutos; el watchdog se encargara de una ejecucion atascada.'
    } else {
        $publishedInfo = Get-ScheduledTaskInfo -TaskName $publishedTask
        Write-Host ("Published termino. LastTaskResult=" + $publishedInfo.LastTaskResult)
    }
}

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
Write-Host 'Publicando diagnostico local...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'publish-local-health.ps1')

Write-Host ''
Write-Host 'SeLoRecordamos queda configurado sin ventanas visibles.' -ForegroundColor Green
Write-Host 'Busqueda: cada hora :05. Historico: cada hora :20. Watchdog: cada 15 min. Listener: continuo desde inicio de sesion.'
