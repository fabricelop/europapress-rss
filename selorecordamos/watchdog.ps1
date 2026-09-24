$ErrorActionPreference = 'Continue'

$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$log = Join-Path $runtime 'watchdog.log'

function Add-Log([string]$text) {
    "[$(Get-Date -Format s)] $text" | Add-Content $log
}

function Enable-IfNeeded([string]$name) {
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        if ($task.State -eq 'Disabled') {
            Enable-ScheduledTask -TaskName $name | Out-Null
            Add-Log "$name estaba deshabilitada; reactivada"
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        }
        return $task
    } catch {
        Add-Log "ERROR: no existe o no se puede leer $name - $($_.Exception.Message)"
        return $null
    }
}

function Ensure-Listener {
    $name = 'SeLoRecordamos-Telegram'
    $task = Enable-IfNeeded $name
    if ($null -eq $task) { return }
    if ($task.State -ne 'Running') {
        try {
            Start-ScheduledTask -TaskName $name
            Add-Log "$name no estaba activo; arrancado"
        } catch {
            Add-Log "ERROR arrancando $name - $($_.Exception.Message)"
        }
    }
}

function Ensure-HourlyTask([string]$name, [int]$maxIdleMinutes = 80, [int]$maxRunMinutes = 30) {
    $task = Enable-IfNeeded $name
    if ($null -eq $task) { return }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $name
        $now = Get-Date
        $last = $info.LastRunTime
        $hasLast = $last -and $last.Year -gt 2000
        $age = if ($hasLast) { ($now - $last).TotalMinutes } else { 999999 }

        if ($task.State -eq 'Running') {
            if ($hasLast -and $age -gt $maxRunMinutes) {
                Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Start-ScheduledTask -TaskName $name
                Add-Log "$name llevaba $([math]::Round($age,1)) min ejecutandose; reiniciada"
            }
            return
        }

        if (-not $hasLast -or $age -gt $maxIdleMinutes) {
            Start-ScheduledTask -TaskName $name
            Add-Log "$name llevaba $([math]::Round($age,1)) min sin ejecutar; lanzada"
        }
    } catch {
        Add-Log "ERROR comprobando $name - $($_.Exception.Message)"
    }
}

Add-Log 'Inicio watchdog'
Ensure-Listener
Ensure-HourlyTask 'SeLoRecordamos-Search' 80 30

# Search y Published comparten el mismo repositorio Git local. Nunca arrancamos
# Published mientras Search siga en ejecución para evitar index.lock/rebases cruzados.
$searchNow = Get-ScheduledTask -TaskName 'SeLoRecordamos-Search' -ErrorAction SilentlyContinue
if ($null -eq $searchNow -or $searchNow.State -ne 'Running') {
    Ensure-HourlyTask 'SeLoRecordamos-Published' 80 30
} else {
    Add-Log 'Published aplazado: Search sigue activo'
}

Add-Log 'Fin watchdog'
