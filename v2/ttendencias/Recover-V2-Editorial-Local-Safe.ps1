# TTActualidad V2: diagnóstico y recuperación conservadora de la tarea editorial.
# Solo se ejecuta en el Windows del usuario; NO abre ni toca V1.
# Guarda las evidencias localmente, nunca las publica en GitHub.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$top30TaskName = 'TTActualidadV2-Top30-15m'
$profile = Join-Path $root 'ChromeProfile'
$flagPath = Join-Path $root 'auto-editorial-v2.enabled'
$statusPath = Join-Path $root 'daemon-status.json'
$logDir = Join-Path $root 'editorial-auto-logs'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$reportPath = Join-Path $root 'v2-recovery-report.txt'
function Emit([string]$name,[string]$value) {
    $line = $name + '=' + $value
    Write-Host $line
    Add-Content -LiteralPath $reportPath -Value $line -Encoding UTF8
}
Set-Content -LiteralPath $reportPath -Value ('TT_V2_RECOVERY_AT=' + [DateTimeOffset]::UtcNow.ToString('o')) -Encoding UTF8
function V2Processes {
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    return @($all | Where-Object {
        $line = [string]$_.CommandLine
        # Only V2-specific executable command lines.
        ($line -match '(?i)(editorial_daemon_v2|Run-V2-Editorial-Auto|recover_existing_chat_v2|incident_worker_v2)\.(py|ps1)') -or
        ($_.Name -ieq 'chrome.exe' -and $line.Contains($profile))
    })
}
function Top30Healthy([string]$taskState,[int]$lastResult,[double]$lastRunAge,[double]$sourceAge) {
    # Ambos relojes importan: exito del programador no implica captura GitHub.
    return $taskState -eq 'Ready' -and $lastResult -eq 0 -and
        $lastRunAge -ge 0 -and $lastRunAge -lt 25 -and
        $sourceAge -ge -2 -and $sourceAge -lt 20
}
function RestoreTop30 {
    # Sin esta captura la cola puede tener pendientes, pero el consumidor
    # rechaza todos los envios: exige historial con menos de 20 minutos.
    $task = Get-ScheduledTask -TaskName $top30TaskName -ErrorAction SilentlyContinue
    $taskState = if ($task) { [string]$task.State } else { 'MISSING' }
    Emit 'TT_V2_TOP30_TASK_BEFORE' $taskState
    $info = if ($task) { Get-ScheduledTaskInfo -TaskName $top30TaskName -ErrorAction SilentlyContinue } else { $null }
    if ($info) {
        Emit 'TT_V2_TOP30_LAST_RUN' ([string]$info.LastRunTime)
        Emit 'TT_V2_TOP30_LAST_RESULT' ([string]$info.LastTaskResult)
    }
    if ($taskState -eq 'Running') {
        Emit 'TT_V2_TOP30_REPAIR' 'RUNNING_NOT_INTERRUPTED_CHECK_LOGS'
        return
    }
    $lastRunAge = if ($info -and $info.LastRunTime.Year -gt 2000) {
        ((Get-Date) - $info.LastRunTime).TotalMinutes
    } else { [double]::PositiveInfinity }
    # Un tick Windows correcto solo confirma el trigger, NO que la Action
    # haya guardado un Top30 nuevo. Verificar el historial real en GitHub.
    $sourceAge = [double]::PositiveInfinity
    try {
        $historyUrl = 'https://api.github.com/repos/fabricelop/europapress-rss/contents/v2/ttendencias/state/history.json?ref=feature%2Fttactualidad-v2-clean'
        $historyResponse = Invoke-RestMethod -Uri $historyUrl -Headers @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-top30-health' } -TimeoutSec 20
        $historyText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($historyResponse.content -replace '\s','')))
        $history = $historyText | ConvertFrom-Json
        $observed = [DateTimeOffset]::Parse([string]$history.observed_at)
        $sourceAge = ([DateTimeOffset]::UtcNow - $observed).TotalMinutes
        Emit 'TT_V2_TOP30_SOURCE_AGE_MINUTES' ([Math]::Round($sourceAge,1).ToString([Globalization.CultureInfo]::InvariantCulture))
    } catch {
        Emit 'TT_V2_TOP30_SOURCE_CHECK' 'UNAVAILABLE_NOT_ASSUMED_HEALTHY'
    }
    $lastResult = if ($info) { [int]$info.LastTaskResult } else { -1 }
    $healthy = Top30Healthy $taskState $lastResult $lastRunAge $sourceAge
    if ($healthy) {
        Emit 'TT_V2_TOP30_REPAIR' 'RECENT_SUCCESS_NO_ACTION'
        return
    }
    # Fijar una revision exacta de GitHub antes de descargar los modulos.
    # Solo los ficheros de Top30 y, si falta, su cliente GitHub compartido.
    $repo = 'fabricelop/europapress-rss'
    $branch = 'feature/ttactualidad-v2-clean'
    $headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-top30-recovery' }
    $commit = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/commits/' + [uri]::EscapeDataString($branch)) -Headers $headers -TimeoutSec 20
    $sha = [string]$commit.sha
    if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'No se pudo verificar commit V2 para Top30' }
    foreach ($file in @('top30_tick_v2.py','Run-V2-Top30-Tick.ps1','Install-V2-Top30-15min.ps1','persist_capture_github.py')) {
        $target = Join-Path $root $file
        if ($file -eq 'persist_capture_github.py' -and (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $temp = $target + '.download'
        $url = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/' + $file
        Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 30
        if ((Get-Item -LiteralPath $temp).Length -lt 100) { throw ('Descarga Top30 incompleta: ' + $file) }
        if ($file.EndsWith('.ps1')) {
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$parseErrors) | Out-Null
            if ($parseErrors.Count -gt 0) { throw ('Sintaxis Top30 invalida: ' + $file) }
        }
        Move-Item -LiteralPath $temp -Destination $target -Force
    }
    Emit 'TT_V2_TOP30_REPAIR_COMMIT' $sha
    & (Join-Path $root 'Install-V2-Top30-15min.ps1')
    $installed = Get-ScheduledTask -TaskName $top30TaskName -ErrorAction Stop
    if ($installed.State -eq 'Disabled') { throw 'Top30 V2 no pudo reactivarse' }
    # Una captura inmediata; las posteriores quedan programadas cada 15 min.
    & (Join-Path $root 'Run-V2-Top30-Tick.ps1')
    Emit 'TT_V2_TOP30_REPAIR' 'TASK_REARMED_AND_TICK_EXECUTED_VERIFY_WORKFLOW'
}
if ($SelfTest) {
    if (-not (Top30Healthy 'Ready' 0 4 6)) { throw 'Top30 sano rechazado' }
    if (Top30Healthy 'Ready' 0 4 120) { throw 'Historial obsoleto aceptado' }
    if (Top30Healthy 'Disabled' 0 4 6) { throw 'Tarea deshabilitada aceptada' }
    if (Top30Healthy 'Ready' 1 4 6) { throw 'Tick fallido aceptado' }
    if (Top30Healthy 'Ready' 0 31 6) { throw 'Programador obsoleto aceptado' }
    Write-Host 'TT_V2_TOP30_RECOVERY_SELFTEST=PASS'
    return
}
try {
    RestoreTop30
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $state = if ($task) { [string]$task.State } else { 'MISSING' }
    Emit 'TT_V2_TASK_STATE_BEFORE' $state
    $enabled = if (Test-Path -LiteralPath $flagPath) {
        (Get-Content -LiteralPath $flagPath -Raw -Encoding UTF8).Trim() -eq 'TT_V2_AUTO_EDITORIAL_ENABLED=YES'
    } else { $false }
    Emit 'TT_V2_FLAG_ENABLED' $(if ($enabled) { 'YES' } else { 'NO' })
    if (Test-Path -LiteralPath $statusPath) {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Emit 'TT_V2_LAST_DAEMON_STATE' ([string]$status.state)
        Emit 'TT_V2_LAST_DAEMON_AT' ([string]$status.at)
    } else { Emit 'TT_V2_LAST_DAEMON_STATE' 'MISSING' }
    $processes = @(V2Processes)
    $chrome = @($processes | Where-Object { $_.Name -ieq 'chrome.exe' })
    $workers = @($processes | Where-Object { $_.Name -ine 'chrome.exe' })
    Emit 'TT_V2_CHROME_PROCESSES' ([string]$chrome.Count)
    Emit 'TT_V2_WORKER_PROCESSES' ([string]$workers.Count)
    if ($state -eq 'Running' -or $workers.Count -gt 0) {
        if ($state -eq 'Running' -and $workers.Count -eq 0) {
            Emit 'TT_V2_REPAIR_RESULT' 'RUNNING_TASK_WITHOUT_WORKER_CHECK_TASK_LOGS'
            exit 2
        }
        if (Test-Path -LiteralPath $statusPath) {
            $last = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$last.at)).TotalMinutes
            if ($age -gt 15) {
                Emit 'TT_V2_DAEMON_HEARTBEAT_STALE_MINUTES' ([Math]::Round($age,1).ToString([Globalization.CultureInfo]::InvariantCulture))
                Emit 'TT_V2_REPAIR_RESULT' 'WORKER_PRESENT_BUT_NOT_PROGRESSING_CHECK_LOGS_NO_FORCE_STOP'
                exit 2
            }
        }
        Emit 'TT_V2_REPAIR_RESULT' 'WORKER_PRESENT_RECENT_HEARTBEAT_NO_ACTION'
        exit 0
    }
    if ($chrome.Count -gt 0) {
        Emit 'TT_V2_REPAIR_RESULT' 'BLOCKED_V2_CHROME_OPEN_NO_TERMINATION'
        exit 2
    }
    if ($state -eq 'Ready' -and $enabled) {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Emit 'TT_V2_START_REQUESTED' 'YES'
        Start-Sleep -Seconds 4
        $after = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Emit 'TT_V2_TASK_STATE_AFTER' ([string]$after.State)
        Emit 'TT_V2_REPAIR_RESULT' 'START_REQUESTED_CHECK_LOGS_FOR_JOB'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $profile -PathType Container)) {
        Emit 'TT_V2_REPAIR_RESULT' 'BLOCKED_NO_V2_AUTHENTICATED_CHROME_PROFILE'
        exit 3
    }
    # Install-V2-Editorial-Auto performs recovery before new messages,
    # checks Python/Playwright, runs tests, and fails closed on uncertainty.
    $repo = 'fabricelop/europapress-rss'
    $ref = 'feature/ttactualidad-v2-clean'
    $headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-safe-recovery' }
    $commit = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/commits/' + [uri]::EscapeDataString($ref)) -Headers $headers -TimeoutSec 20
    $sha = [string]$commit.sha
    if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'No se pudo verificar commit V2' }
    $installer = Join-Path $root 'Install-V2-Editorial-Auto.ps1'
    $url = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/Install-V2-Editorial-Auto.ps1'
    Invoke-WebRequest -Uri $url -OutFile $installer -Headers $headers -UseBasicParsing -TimeoutSec 30
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw 'Instalador V2 descargado con errores de sintaxis' }
    Emit 'TT_V2_INSTALL_COMMIT' $sha
    Emit 'TT_V2_INSTALL_ACTION' 'SAFE_REINSTALL_WITH_EXISTING_CHAT_RECOVERY'
    & $installer
    Emit 'TT_V2_REPAIR_RESULT' 'INSTALLER_FINISHED_VERIFY_NEW_JOB_IN_GITHUB'
    exit 0
} catch {
    Emit 'TT_V2_REPAIR_RESULT' 'BLOCKED_OR_FAILED_NO_FORCE_RETRY'
    Emit 'TT_V2_ERROR' ($_.Exception.Message -replace '[\r\n]+',' ')
    exit 1
} finally {
    foreach ($logSpec in @(
        @{ Dir=$logDir; Filter='auto-*.log'; Label='TT_V2_LATEST_EDITORIAL_LOG' },
        @{ Dir=$logDir; Filter='auto-*.stderr.log'; Label='TT_V2_LATEST_EDITORIAL_ERROR' },
        @{ Dir=(Join-Path $root 'logs-top30'); Filter='top30-*.err.log'; Label='TT_V2_LATEST_TOP30_ERROR' }
    )) {
        if (Test-Path -LiteralPath $logSpec.Dir) {
            $latest = Get-ChildItem -LiteralPath $logSpec.Dir -Filter $logSpec.Filter -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                Emit $logSpec.Label $latest.FullName
                Get-Content -LiteralPath $latest.FullName -Tail 12 -ErrorAction SilentlyContinue
            }
        }
    }
    Emit 'TT_V1_MODIFIED' 'NO'
}
