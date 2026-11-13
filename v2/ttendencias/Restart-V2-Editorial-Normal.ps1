# Reinicio manual solicitado: solo consumidor editorial TTActualidad V2.
# Permite interrumpir el chat en curso. No modifica colas/diarios/GitHub ni V1.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$profile = Join-Path $root 'ChromeProfile'
$taskName = 'TTActualidadV2-Editorial-Auto'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$statusFile = Join-Path $root 'daemon-status.json'
$report = Join-Path $root 'v2-normal-restart-report.txt'
New-Item -ItemType Directory -Path $root -Force | Out-Null
Set-Content -LiteralPath $report -Value ('TT_V2_RESTART_REQUESTED_AT=' + [DateTimeOffset]::UtcNow.ToString('o')) -Encoding UTF8
function Log([string]$name, [string]$value) {
    $line = $name + '=' + $value
    Write-Host $line
    Add-Content -LiteralPath $report -Value $line -Encoding UTF8
}
function Scan {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop)
}
function V2Roots($all) {
    return @($all | Where-Object {
        $command = [string]$_.CommandLine
        $name = [string]$_.Name
        if ($name -ieq 'chrome.exe') {
            return $command.Contains($profile)
        }
        if ($name -match '^(?i:python|pythonw|py|powershell|pwsh)(?:\.exe)?$') {
            return $command.Contains($root) -and
                $command -match '(?i)(editorial_daemon_v2|Run-V2-Editorial-Auto|recover_existing_chat_v2|incident_worker_v2|editorial_run_v2|recover_one_editorial_native_cdp|recover_sent_v2)\.(py|ps1)'
        }
        return $false
    })
}
function V2Tree($all) {
    $seeds = @(V2Roots $all)
    $ids = @{}
    foreach ($proc in $seeds) { $ids[[int]$proc.ProcessId] = $true }
    # Include descendants of V2 roots even if Chrome children omit --user-data-dir.
    # Refuse to expand through unrelated processes: only declared roots/descendants.
    do {
        $count = $ids.Count
        foreach ($proc in $all) {
            if ($ids.ContainsKey([int]$proc.ParentProcessId) -and
                -not $ids.ContainsKey([int]$proc.ProcessId)) {
                $ids[[int]$proc.ProcessId] = $true
            }
        }
    } while ($ids.Count -gt $count)
    return @($all | Where-Object { $ids.ContainsKey([int]$_.ProcessId) })
}
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Log 'TT_V2_TASK_BEFORE' ([string]$task.State)
    # Block automatic restart during teardown, including three-minute trigger.
    Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=NO" + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
        Log 'TT_V2_STOP_TASK_WARNING' ($_.Exception.Message -replace '[\r\n]+',' ')
    }
    Start-Sleep -Seconds 2
    $all = Scan
    $owned = @(V2Tree $all)
    Log 'TT_V2_OWNED_PROCESSES_BEFORE_STOP' ([string]$owned.Count)
    # Windows PowerShell 5.1: redirect taskkill stderr to files so a PID
    # disappearing during shutdown does not terminate this script.
    # Verify PID identity immediately before signalling it.
    $roots = @(V2Roots $all)
    foreach ($proc in $roots) {
        if ($proc.ProcessId -eq $PID) { throw 'No terminar el proceso del propio script' }
        $current = @(Scan | Where-Object { $_.ProcessId -eq $proc.ProcessId })
        if ($current.Count -eq 0) {
            Log 'TT_V2_ALREADY_EXITED' ([string]$proc.ProcessId)
            continue
        }
        $actualV2 = @(V2Roots $current)
        if ($actualV2.Count -ne 1 -or [string]$current[0].CreationDate -ne [string]$proc.CreationDate) {
            Log 'TT_V2_PID_CHANGED_SKIP' ([string]$proc.ProcessId)
            continue
        }
        $stdout = Join-Path $root ('v2-stop-' + $proc.ProcessId + '.stdout.log')
        $stderr = Join-Path $root ('v2-stop-' + $proc.ProcessId + '.stderr.log')
        $killed = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID',([string]$proc.ProcessId),'/T','/F') -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($killed.ExitCode -ne 0) {
            # A nonzero exit is not a complete stop; only the final scan
            # below decides whether restarting would be safe.
            Log 'TT_V2_TASKKILL_NONZERO' (([string]$proc.ProcessId) + ':' + $killed.ExitCode)
        }
    }
    Start-Sleep -Seconds 3
    $remaining = @(V2Tree (Scan))
    Log 'TT_V2_OWNED_PROCESSES_AFTER_STOP' ([string]$remaining.Count)
    if ($remaining.Count -gt 0) {
        Log 'TT_V2_RESULT' 'BLOCKED_PROCESSES_STILL_RUNNING_NO_RESTART'
        exit 2
    }
    $daemon = Join-Path $root 'editorial_daemon_v2.py'
    $recovery = Join-Path $root 'recover_existing_chat_v2.py'
    $runner = Join-Path $root 'Run-V2-Editorial-Auto.ps1'
    foreach ($required in @($daemon,$recovery,$runner)) {
        if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
            Log 'TT_V2_RESULT' 'BLOCKED_MISSING_LOCAL_MODULES'
            exit 3
        }
    }
    if (!(Test-Path -LiteralPath $profile -PathType Container)) {
        Log 'TT_V2_RESULT' 'BLOCKED_MISSING_V2_CHROME_PROFILE'
        exit 4
    }
    [IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=YES" + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
    Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Start-Sleep -Seconds 5
    $after = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Log 'TT_V2_TASK_AFTER' ([string]$after.State)
    if (Test-Path -LiteralPath $statusFile) {
        $status = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Log 'TT_V2_DAEMON_STATE' ([string]$status.state)
        Log 'TT_V2_DAEMON_AT' ([string]$status.at)
    }
    $live = @(V2Tree (Scan))
    Log 'TT_V2_OWNED_PROCESSES_AFTER_START' ([string]$live.Count)
    Log 'TT_V2_RESULT' 'RESTART_REQUESTED_CHECK_NEW_LOG_AND_GITHUB'
    Log 'TT_V1_MODIFIED' 'NO'
} catch {
    Log 'TT_V2_RESULT' 'ERROR_NOT_CONFIRMED'
    Log 'TT_V2_ERROR' ($_.Exception.Message -replace '[\r\n]+',' ')
    Log 'TT_V1_MODIFIED' 'NO'
    exit 1
}
