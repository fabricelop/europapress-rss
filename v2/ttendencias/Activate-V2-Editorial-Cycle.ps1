# Ciclo simple Top30 -> chat -> captura -> liberacion. Solo Tendencias V2.
param([ValidateRange(5,90)][int]$MaxWaitMinutes = 20)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$task = 'TTActualidadV2-Editorial-Auto'
$profile = Join-Path $root 'ChromeProfile'
$repo = 'fabricelop/europapress-rss'
$branch = 'feature/ttactualidad-v2-clean'
$headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-Editorial-Cycle' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$modules = @('editorial_daemon_v2.py','parallel_dispatch_v2.py','incident_retry_v2.py')
$tests = @('test_editorial_completion_v2.py','test_parallel_dispatch_v2.py',
           'test_incident_retry_v2.py','test_auto_editorial_v2.py',
           'test_editorial_daemon_pilot_v2.py')
$support = @('image_daemon_v2.py','Install-V2-Editorial-Auto.ps1')

function Set-EditorialFlag([string]$value) {
    [IO.File]::WriteAllText($flag, $value + [Environment]::NewLine, $utf8)
}
function Get-V2EditorialProcesses {
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    return @($all | Where-Object {
        $line = [string]$_.CommandLine
        (($line -match '(?i)(editorial_daemon_v2|editorial_run_v2|Run-V2-Editorial-Auto|recover_existing_chat_v2|incident_worker_v2)\.(py|ps1)') -and $line.Contains($root)) -or
        ($_.Name -ieq 'chrome.exe' -and $line.Contains($profile))
    })
}
if (-not (Test-Path -LiteralPath $profile -PathType Container)) {
    throw 'Sin perfil Chrome autenticado de Tendencias V2: no se cambia nada.'
}
$scheduled = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if (-not $scheduled -or [string]$scheduled.State -eq 'Disabled') {
    throw 'Tarea editorial V2 ausente o deshabilitada: no se cambia nada.'
}
if (-not (Test-Path -LiteralPath $flag)) { throw 'Falta bandera editorial: no se cambia nada.' }
$oldFlag = (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim()
if ($oldFlag -ne 'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    throw 'El consumidor estaba parado: no se modifica ni se reactiva.'
}

# Un solo SHA inmutable; tests antes de tocar la tarea o el flag.
$head = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/commits/' + [uri]::EscapeDataString($branch)) -Headers $headers -TimeoutSec 25
$sha = [string]$head.sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub no confirmó SHA.' }
$stage = Join-Path $root ('editorial-cycle-stage-' + $sha.Substring(0,12))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$base = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/'
foreach ($name in @($modules + $tests + $support)) {
    $dest = Join-Path $stage $name
    Invoke-WebRequest -Uri ($base + $name) -OutFile $dest -Headers $headers -UseBasicParsing -TimeoutSec 40
    if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -lt 60) {
        throw ('Descarga incompleta: ' + $name)
    }
}
$newDaemon = Get-Content -LiteralPath (Join-Path $stage 'editorial_daemon_v2.py') -Raw
$newPool = Get-Content -LiteralPath (Join-Path $stage 'parallel_dispatch_v2.py') -Raw
if (-not $newDaemon.Contains('settle_failed_job') -or -not $newDaemon.Contains('wave_ready') -or -not $newPool.Contains('MAX_JOB_SESSION_SECONDS = 480')) {
    throw 'El SHA no contiene el nuevo ciclo editorial.'
}
$python = (Get-Command py.exe -ErrorAction Stop).Source
$oldPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $stage + ';' + $root
$stdout = Join-Path $stage 'preflight.stdout.log'
$stderr = Join-Path $stage 'preflight.stderr.log'
try {
    $test = Start-Process -FilePath $python -ArgumentList @('-3','-m','unittest','-q','test_editorial_completion_v2','test_parallel_dispatch_v2','test_incident_retry_v2','test_auto_editorial_v2','test_editorial_daemon_pilot_v2') -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($test.ExitCode -ne 0) {
        Get-Content -LiteralPath $stderr -Tail 18 | ForEach-Object { Write-Host $_ }
        throw 'Fallo de pruebas: no se ha instalado nada.'
    }
} finally {
    $env:PYTHONPATH = $oldPythonPath
}
Write-Host ('TT_V2_EDITORIAL_CYCLE_STAGE_TESTS=OK sha=' + $sha.Substring(0,12))

$backup = Join-Path $root ('editorial-cycle-backup-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))
$copied = $false
$activated = $false
try {
    # Drenaje cooperativo. Nunca cerrar Chrome a la fuerza ni tocar V1/Noticias/Imagenes.
    Set-EditorialFlag 'TT_V2_AUTO_EDITORIAL_ENABLED=NO'
    Write-Host 'TT_V2_EDITORIAL_CYCLE_DRAINING=YES'
    $deadline = [DateTime]::UtcNow.AddMinutes($MaxWaitMinutes)
    $clearChecks = 0
    do {
        if (@(Get-V2EditorialProcesses).Count -eq 0) { $clearChecks++ } else { $clearChecks = 0 }
        if ($clearChecks -ge 2) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Quedan procesos editoriales: no se cerrarán a la fuerza.' }
        Start-Sleep -Seconds 8
    } while ($true)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in $modules) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $backup $name) -ErrorAction Stop
    }
    $copied = $true
    foreach ($name in $modules) {
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $root $name) -Force -ErrorAction Stop
    }
    Set-EditorialFlag 'TT_V2_AUTO_EDITORIAL_ENABLED=YES'
    $startedAt = [DateTime]::UtcNow
    Start-ScheduledTask -TaskName $task -ErrorAction Stop
    $activated = $true
    Write-Host 'TT_V2_EDITORIAL_CYCLE_INSTALLED=YES'
    Write-Host ('TT_V2_EDITORIAL_CYCLE_BACKUP=' + $backup)
    $statusPath = Join-Path $root 'daemon-status.json'
    $healthy = $false
    for ($i=0; $i -lt 18; $i++) {
        Start-Sleep -Seconds 5
        if (-not (Test-Path -LiteralPath $statusPath)) { continue }
        try {
            $state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($state.service -eq 'ttactualidad-v2' -and [DateTimeOffset]::Parse([string]$state.at).UtcDateTime -ge $startedAt -and $state.state -in @('STARTED','WORKING','WAIT_NO_CURRENT_JOB','WAIT_SOURCE','JOB_SETTLED','JOB_SETTLEMENT_RETRY','INCIDENT_REVIEW')) {
                $healthy = $true
                break
            }
        } catch { }
    }
    if ($healthy) { Write-Host 'TT_V2_EDITORIAL_CYCLE_ACTIVE=YES' }
    else { Write-Host 'TT_V2_EDITORIAL_CYCLE_ACTIVE=CHECK_LOGS' }
} catch {
    $reason = $_.Exception.Message
    if ($copied -and -not $activated -and @(Get-V2EditorialProcesses).Count -eq 0) {
        foreach ($name in $modules) {
            Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $root $name) -Force
        }
        Write-Host 'TT_V2_EDITORIAL_CYCLE_ROLLBACK=OK'
    }
    if (-not $activated) { Set-EditorialFlag $oldFlag }
    throw $reason
}
