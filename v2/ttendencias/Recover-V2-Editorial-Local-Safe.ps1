# TTActualidad V2: diagnóstico y recuperación conservadora de la tarea editorial.
# Solo se ejecuta en el Windows del usuario; NO abre ni toca V1.
# Guarda las evidencias localmente, nunca las publica en GitHub.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
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
try {
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
        Emit 'TT_V2_REPAIR_RESULT' 'ALREADY_ACTIVE_OR_RECOVERING_NO_ACTION'
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
    if (Test-Path -LiteralPath $logDir) {
        $latest = Get-ChildItem -LiteralPath $logDir -Filter 'auto-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            Emit 'TT_V2_LATEST_LOG' $latest.FullName
            Get-Content -LiteralPath $latest.FullName -Tail 12 -ErrorAction SilentlyContinue
        }
    }
    Emit 'TT_V1_MODIFIED' 'NO'
}
