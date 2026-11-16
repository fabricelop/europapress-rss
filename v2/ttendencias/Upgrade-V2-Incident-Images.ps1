# Instala solo RE-X de incidencias y selección de imagen RE/RE-X histórica.
# Sin cambios en V1, sin publicaciones, sin matar procesos ni reenvíos dudosos.
param([ValidateRange(5,60)][int]$WaitMinutes = 25)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$tasks = @('TTActualidadV2-Editorial-Auto','TTActualidadV2-Images-Auto')
$flags = @('auto-editorial-v2.enabled','auto-images-v2.enabled')
$files = @('sync_private_re_v2.py','re_request_v2.py','incident_retry_v2.py',
           'image_worker_v2.py','test_sync_private_re_v2.py',
           'test_incident_retry_v2.py','test_image_worker_v2.py')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stage = Join-Path $root ('incident-image-stage-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $root ('incident-image-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
$taskEnabled = @{}
$flagContents = @{}
$installed = @()
if (!(Test-Path -LiteralPath $root -PathType Container)) { throw 'TT_V2_INSTALLATION_MISSING' }
foreach ($name in $tasks) {
    $taskEnabled[$name] = (Get-ScheduledTask -TaskName $name -ErrorAction Stop).State -ne 'Disabled'
}
foreach ($name in $flags) {
    $path = Join-Path $root $name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw ('TT_V2_FLAG_MISSING=' + $name) }
    $flagContents[$name] = [IO.File]::ReadAllText($path)
}
try {
    foreach ($name in $tasks) {
        if ($taskEnabled[$name]) { Disable-ScheduledTask -TaskName $name | Out-Null }
    }
    foreach ($name in $flags) {
        $kind = if ($name -like '*editorial*') { 'EDITORIAL' } else { 'IMAGES' }
        [IO.File]::WriteAllText((Join-Path $root $name),
            ('TT_V2_AUTO_' + $kind + '_ENABLED=NO' + [Environment]::NewLine),$utf8)
    }
    Write-Host 'TT_V2_INCIDENT_IMAGES=WAITING_FOR_ACTIVE_CHATS'
    $until = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $runningTasks = @($tasks | Where-Object { (Get-ScheduledTask -TaskName $_).State -eq 'Running' })
        $runningPython = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -in @('python.exe','pythonw.exe','py.exe') -and $_.CommandLine -and
            $_.CommandLine.Contains($root) -and
            $_.CommandLine -match '(editorial_daemon_v2|editorial_run_v2|image_daemon_v2|image_worker_v2)\.py'
        })
        $runningChrome = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') -and
            $_.CommandLine.Contains((Join-Path $root 'ChromeProfile'))
        })
        if (!$runningTasks.Count -and !$runningPython.Count -and !$runningChrome.Count) { break }
        if ((Get-Date) -ge $until) { throw 'TT_V2_ACTIVE_CHATS_TIMEOUT_NO_FILES_CHANGED' }
        Start-Sleep -Seconds 10
    } while ($true)
    $headers = @{ 'User-Agent' = 'TTActualidadV2-Incident-Image-Upgrade' }
    $ref = 'https://api.github.com/repos/fabricelop/europapress-rss/commits/' +
        [Uri]::EscapeDataString('feature/ttactualidad-v2-clean')
    $sha = [string](Invoke-RestMethod -Uri $ref -Headers $headers -UseBasicParsing).sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'TT_V2_REF_NOT_VERIFIED' }
    $base = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/' + $sha + '/v2/ttendencias/'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in $files) {
        $target = Join-Path $root $name
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw ('TT_V2_MODULE_MISSING=' + $name) }
        $dest = Join-Path $stage $name
        Invoke-WebRequest -Uri ($base + $name) -Headers $headers -UseBasicParsing -OutFile $dest
        if ((Get-Item -LiteralPath $dest).Length -lt 700) { throw ('TT_V2_DOWNLOAD_INVALID=' + $name) }
    }
    if (!([IO.File]::ReadAllText((Join-Path $stage 'image_worker_v2.py')).Contains('recent RE/RE-X revisions')) -or
        !([IO.File]::ReadAllText((Join-Path $stage 'sync_private_re_v2.py')).Contains('incident_hints'))) {
        throw 'TT_V2_INCIDENT_IMAGE_VERSION_NOT_VERIFIED'
    }
    $py = (Get-Command py.exe -ErrorAction Stop).Source
    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = $stage + ';' + $root
        $result = Start-Process -FilePath $py -ArgumentList @('-3','-m','unittest','-q',
            'test_sync_private_re_v2','test_incident_retry_v2','test_image_worker_v2') `
            -WorkingDirectory $stage -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $stage 'tests.stdout.log') `
            -RedirectStandardError (Join-Path $stage 'tests.stderr.log')
        if ($result.ExitCode -ne 0) { throw 'TT_V2_INCIDENT_IMAGE_TESTS_FAILED' }
    } finally { $env:PYTHONPATH = $oldPythonPath }
    foreach ($name in $files) {
        $target = Join-Path $root $name
        Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name) -ErrorAction Stop
        [IO.File]::Replace((Join-Path $stage $name),$target,
            (Join-Path $backup ('replaced-' + $name)))
        $installed += $name
    }
    Write-Host 'TT_V2_INCIDENT_REX_PC_INSTALLED=YES'
    Write-Host 'TT_V2_RE_IMAGES_OUTSIDE_TOP30=INSTALLED'
    Write-Host ('TT_V2_PINNED_COMMIT=' + $sha)
    Write-Host 'TT_V2_V1_AND_PUBLICATION=UNTOUCHED'
} catch {
    foreach ($name in $installed) {
        Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $root $name) -Force
    }
    throw
} finally {
    foreach ($name in $flags) {
        [IO.File]::WriteAllText((Join-Path $root $name),$flagContents[$name],$utf8)
    }
    foreach ($name in $tasks) {
        if ($taskEnabled[$name]) {
            Enable-ScheduledTask -TaskName $name | Out-Null
            $kind = if ($name -like '*Editorial*') { 'auto-editorial-v2.enabled' } else { 'auto-images-v2.enabled' }
            if ($flagContents[$kind].Contains('=YES')) { Start-ScheduledTask -TaskName $name }
        }
    }
}
