# Solo propiedad de Chrome V2 y diagnostico de imagenes. Nunca interrumpe chats.
# La editorial solo cambia su deteccion de PID; ni texto ni V1 se modifican.
param([ValidateRange(5,60)][int]$WaitMinutes = 25)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Images-Auto'
$flag = Join-Path $root 'auto-images-v2.enabled'
$editorialTaskName = 'TTActualidadV2-Editorial-Auto'
$editorialFlag = Join-Path $root 'auto-editorial-v2.enabled'
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (!(Test-Path -LiteralPath $root -PathType Container) -or
    !(Test-Path -LiteralPath $flag -PathType Leaf) -or
    !(Test-Path -LiteralPath $editorialFlag -PathType Leaf)) {
    throw 'TT_V2_IMAGES_INSTALLATION_NOT_FOUND'
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$editorialTask = Get-ScheduledTask -TaskName $editorialTaskName -ErrorAction Stop
$taskWasEnabled = $task.State -ne 'Disabled'
$editorialTaskWasEnabled = $editorialTask.State -ne 'Disabled'
$flagWasEnabled = (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() -eq 'TT_V2_AUTO_IMAGES_ENABLED=YES'
$editorialFlagWasEnabled = (Get-Content -LiteralPath $editorialFlag -Raw -Encoding UTF8).Trim() -eq 'TT_V2_AUTO_EDITORIAL_ENABLED=YES'
$stage = Join-Path $root ('image-send-stage-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $root ('image-send-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
$files = @('image_job_v2.py','image_target_tracker_v2.py','image_worker_v2.py',
           'image_retry_status_v2.py','web_top30_v2.py',
           'editorial_run_v2.py','chrome_profile_process_v2.py',
           'test_image_worker_v2.py','test_image_retry_status_v2.py',
           'test_chrome_profile_process_v2.py')
$installed = @()
try {
    if ($taskWasEnabled) { Disable-ScheduledTask -TaskName $taskName | Out-Null }
    if ($editorialTaskWasEnabled) { Disable-ScheduledTask -TaskName $editorialTaskName | Out-Null }
    [IO.File]::WriteAllText($flag, 'TT_V2_AUTO_IMAGES_ENABLED=NO' + [Environment]::NewLine, $utf8)
    [IO.File]::WriteAllText($editorialFlag, 'TT_V2_AUTO_EDITORIAL_ENABLED=NO' + [Environment]::NewLine, $utf8)
    Write-Host 'TT_V2_IMAGE_SEND=WAITING_FOR_ACTIVE_CHATS'
    $until = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $runningTask = (Get-ScheduledTask -TaskName $taskName).State -eq 'Running' -or
                       (Get-ScheduledTask -TaskName $editorialTaskName).State -eq 'Running'
        $pythonWorkers = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -in @('python.exe','pythonw.exe','py.exe') -and $_.CommandLine -and
            $_.CommandLine.Contains($root) -and $_.CommandLine -match '(editorial_daemon_v2|editorial_run_v2|image_daemon_v2|image_worker_v2)\.py'
        })
        $chromeWorkers = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') -and
            $_.CommandLine.Contains((Join-Path $root 'ChromeProfile'))
        })
        if (!$runningTask -and !$pythonWorkers.Count -and !$chromeWorkers.Count) { break }
        if ((Get-Date) -ge $until) { throw 'TT_V2_IMAGE_SEND_TIMEOUT_NO_FILES_CHANGED' }
        Start-Sleep -Seconds 10
    } while ($true)

    $headers = @{ 'User-Agent' = 'TTActualidadV2-image-send-upgrader' }
    $ref = 'https://api.github.com/repos/fabricelop/europapress-rss/commits/' +
        [Uri]::EscapeDataString('feature/ttactualidad-v2-clean')
    $sha = [string](Invoke-RestMethod -Uri $ref -Headers $headers -UseBasicParsing).sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'TT_V2_IMAGE_SEND_REF_NOT_VERIFIED' }
    $base = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/' + $sha + '/v2/ttendencias/'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in $files) {
        $target = Join-Path $root $name
        if ($name -ne 'chrome_profile_process_v2.py' -and
            $name -ne 'test_chrome_profile_process_v2.py' -and
            $name -ne 'image_retry_status_v2.py' -and
            $name -ne 'test_image_retry_status_v2.py' -and
            !(Test-Path -LiteralPath $target -PathType Leaf)) {
            throw ('TT_V2_IMAGE_SEND_MODULE_MISSING=' + $name)
        }
        Invoke-WebRequest -Uri ($base + $name) -Headers $headers -UseBasicParsing -OutFile (Join-Path $stage $name)
        if ((Get-Item -LiteralPath (Join-Path $stage $name)).Length -lt 1000) {
            throw ('TT_V2_IMAGE_SEND_DOWNLOAD_INVALID=' + $name)
        }
    }
    $worker = [IO.File]::ReadAllText((Join-Path $stage 'image_worker_v2.py'))
    if (!$worker.Contains('IMAGE_SEND_PROTOCOL = 2') -or !$worker.Contains('def submit_image_prompt(')) {
        throw 'TT_V2_IMAGE_SEND_EXPECTED_PROTOCOL_MISSING'
    }
    if (!$worker.Contains('def publish_image_retry_summary(') -or
        !([IO.File]::ReadAllText((Join-Path $stage 'web_top30_v2.py'))).Contains('def image_retry_public_status(')) {
        throw 'TT_V2_IMAGE_RETRY_SUMMARY_CONTRACT_MISSING'
    }
    $editorial = [IO.File]::ReadAllText((Join-Path $stage 'editorial_run_v2.py'))
    $ownership = [IO.File]::ReadAllText((Join-Path $stage 'chrome_profile_process_v2.py'))
    if (!$worker.Contains('return exact_chrome_profile_pids(PROFILE)') -or
        !$editorial.Contains('return exact_chrome_profile_pids(PROFILE)') -or
        !$ownership.Contains('def matching_pids(')) {
        throw 'TT_V2_CHROME_EXACT_PROFILE_GUARD_MISSING'
    }
    $python = (Get-Command py.exe -ErrorAction Stop).Source
    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = $stage + ';' + $root
        $test = Start-Process -FilePath $python -ArgumentList @('-3','-m','unittest','-q','test_image_worker_v2','test_image_retry_status_v2','test_chrome_profile_process_v2') -WorkingDirectory $stage -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput (Join-Path $stage 'tests.stdout.log') -RedirectStandardError (Join-Path $stage 'tests.stderr.log')
        if ($test.ExitCode -ne 0) { throw 'TT_V2_IMAGE_SEND_TESTS_FAILED' }
    } finally {
        $env:PYTHONPATH = $oldPythonPath
    }
    foreach ($name in $files) {
        $target = Join-Path $root $name
        $old = Join-Path $backup $name
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Copy-Item -LiteralPath $target -Destination $old -ErrorAction Stop
            # .NET Framework (Windows PowerShell 5.1) requires a valid backup path.
            $atomicBackup = Join-Path $backup ('replaced-' + $name)
            [IO.File]::Replace((Join-Path $stage $name), $target, $atomicBackup)
        } else {
            Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $target -ErrorAction Stop
        }
        $installed += $name
    }
    Write-Host 'TT_V2_IMAGE_SEND_INSTALLED=YES'
    Write-Host 'TT_V2_IMAGE_RETRY_SUMMARY=INSTALLED'
    Write-Host 'TT_V2_IMAGE_BACKFILL_AVAILABLE=YES'
    Write-Host 'TT_V2_CHROME_EXACT_PROFILE=INSTALLED'
    Write-Host ('TT_V2_IMAGE_SEND_PINNED_COMMIT=' + $sha)
    Write-Host 'TT_V2_EDITORIAL_LOGIC_AND_V1=UNTOUCHED'
    Write-Host 'TT_V2_PUBLICATION=NO'
} catch {
    foreach ($name in $installed) {
        $old = Join-Path $backup $name
        if (Test-Path -LiteralPath $old -PathType Leaf) {
            Copy-Item -LiteralPath $old -Destination (Join-Path $root $name) -Force
        } else {
            # A newly introduced helper can be rolled back exactly.
            Remove-Item -LiteralPath (Join-Path $root $name) -Force
        }
    }
    throw
} finally {
    [IO.File]::WriteAllText($flag, ('TT_V2_AUTO_IMAGES_ENABLED=' + $(if ($flagWasEnabled) { 'YES' } else { 'NO' })) + [Environment]::NewLine, $utf8)
    [IO.File]::WriteAllText($editorialFlag, ('TT_V2_AUTO_EDITORIAL_ENABLED=' + $(if ($editorialFlagWasEnabled) { 'YES' } else { 'NO' })) + [Environment]::NewLine, $utf8)
    if ($taskWasEnabled) {
        Enable-ScheduledTask -TaskName $taskName | Out-Null
        if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and $flagWasEnabled) {
            Start-ScheduledTask -TaskName $taskName
        }
    }
    if ($editorialTaskWasEnabled) {
        Enable-ScheduledTask -TaskName $editorialTaskName | Out-Null
        if ((Get-ScheduledTask -TaskName $editorialTaskName).State -ne 'Running' -and $editorialFlagWasEnabled) {
            Start-ScheduledTask -TaskName $editorialTaskName
        }
    }
}
