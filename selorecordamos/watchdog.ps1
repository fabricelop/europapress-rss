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


function Check-Editorial-Backlog {
    $monitor = Join-Path $PSScriptRoot 'editorial-health-watch.js'
    if (-not (Test-Path $monitor)) {
        Add-Log 'AVISO: no existe editorial-health-watch.js; comprobar sincronizacion Git'
        return
    }
    try {
        $env:SR_TELEGRAM_BOT_TOKEN = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_BOT_TOKEN', 'User')
        $env:SR_TELEGRAM_CHAT_ID = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_CHAT_ID', 'User')
        & node $monitor 2>&1 | ForEach-Object { Add-Log "EDITORIAL: $_" }
        if ($LASTEXITCODE -ne 0) { Add-Log "AVISO: editorial-health-watch.js termino con codigo $LASTEXITCODE" }
    } catch {
        Add-Log "ERROR comprobando cola editorial: $($_.Exception.Message)"
    }
}

Add-Log 'Inicio watchdog'
Ensure-Listener
Check-Editorial-Backlog
Ensure-HourlyTask 'SeLoRecordamos-Search' 80 30

# Search y Published comparten el mismo repositorio Git local. Nunca arrancamos
# Published mientras Search siga en ejecución para evitar index.lock/rebases cruzados.
$searchNow = Get-ScheduledTask -TaskName 'SeLoRecordamos-Search' -ErrorAction SilentlyContinue
if ($null -eq $searchNow -or $searchNow.State -ne 'Running') {
    Ensure-HourlyTask 'SeLoRecordamos-Published' 80 30
} else {
    Add-Log 'Published aplazado: Search sigue activo'
}

$searchFinal = Get-ScheduledTask -TaskName 'SeLoRecordamos-Search' -ErrorAction SilentlyContinue
$publishedFinal = Get-ScheduledTask -TaskName 'SeLoRecordamos-Published' -ErrorAction SilentlyContinue
if (($null -eq $searchFinal -or $searchFinal.State -ne 'Running') -and ($null -eq $publishedFinal -or $publishedFinal.State -ne 'Running')) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'publish-local-health.ps1') | Out-Null
        Add-Log 'Estado local publicado'
    } catch {
        Add-Log "AVISO publicando estado local - $($_.Exception.Message)"
    }
} else {
    Add-Log 'Estado local aplazado: hay una tarea Git activa'
}

Add-Log 'Fin watchdog'
