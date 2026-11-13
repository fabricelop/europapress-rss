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
    # Keep the original exact PID/creation-date inventory, including
    # V2 Chrome descendants whose command line lacks --user-data-dir.
    # A disappearing PID is normal and never aborts the restart.
    $tracked = @{}
    foreach ($p in $owned) { $tracked[[int]$p.ProcessId] = [string]$p.CreationDate }
    $remaining = @()
    for ($pass = 1; $pass -le 6; $pass++) {
        $snapshot = @(Scan)
        $currentTree = @(V2Tree $snapshot)
        foreach ($p in $currentTree) {
            $tracked[[int]$p.ProcessId] = [string]$p.CreationDate
        }
        # Use the original identities when parents disappeared in between scans.
        $remaining = @($snapshot | Where-Object {
            $id = [int]$_.ProcessId
            $tracked.ContainsKey($id) -and $tracked[$id] -eq [string]$_.CreationDate
        })
        Log 'TT_V2_STOP_PASS' ([string]$pass)
        Log 'TT_V2_STOP_PASS_REMAINING' ([string]$remaining.Count)
        if ($remaining.Count -eq 0) { break }
        # Child-first reduces noisy "process not found" messages. Never
        # send a generic taskkill /IM chrome.exe or terminate a foreign PID.
        foreach ($p in @($remaining | Sort-Object ProcessId -Descending)) {
            $id = [int]$p.ProcessId
            if ($id -eq $PID) { throw 'Se detectó el propio script dentro de V2: cancelar' }
            try {
                $live = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $id) -ErrorAction Stop
                if (!$live -or [string]$live.CreationDate -ne $tracked[$id]) {
                    continue
                }
                Stop-Process -Id $id -Force -ErrorAction Stop
                Log 'TT_V2_STOPPED_PID' ([string]$id)
            } catch {
                # Process-exited races are expected. Do not report an error
                # unless the final verification still finds live V2 processes.
                Log 'TT_V2_STOP_ATTEMPT' ([string]$id)
            }
        }
        Start-Sleep -Seconds 2
    }
    $snapshot = @(Scan)
    $currentTree = @(V2Tree $snapshot)
    foreach ($p in $currentTree) { $tracked[[int]$p.ProcessId] = [string]$p.CreationDate }
    $remaining = @($snapshot | Where-Object {
        $id = [int]$_.ProcessId
        $tracked.ContainsKey($id) -and $tracked[$id] -eq [string]$_.CreationDate
    })
    Log 'TT_V2_OWNED_PROCESSES_AFTER_STOP' ([string]$remaining.Count)
    if ($remaining.Count -gt 0) {
        Log 'TT_V2_REMAINING_PIDS' (($remaining | ForEach-Object { $_.ProcessId }) -join ',')
        Log 'TT_V2_RESULT' 'BLOCKED_V2_PROCESSES_STILL_RUNNING_NO_RESTART'
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
