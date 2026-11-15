# Activación segura del consumidor RE V2 en el Windows del propietario.
# No toca V1, Chrome 9223/9234, ni ningún trabajo de noticias.
# Primero descarga y prueba la actualización; después espera a que el
# consumidor V2 termine por sí mismo antes de cambiar sus módulos.
param([ValidateRange(5,120)][int]$MaxWaitMinutes = 60)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$profile = Join-Path $root 'ChromeProfile'
$repo = 'fabricelop/europapress-rss'
$branch = 'feature/ttactualidad-v2-clean'
$headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-RE-Upgrade' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$files = @('editorial_daemon_v2.py','auto_editorial_policy_v2.py',
           're_request_v2.py','sync_private_re_v2.py',
           'test_auto_editorial_v2.py','test_re_request_v2.py',
           'test_sync_private_re_v2.py')

function Flag([string]$text) {
    [IO.File]::WriteAllText($flag, $text + [Environment]::NewLine, $utf8)
}
function V2ActiveProcesses {
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    return @($all | Where-Object {
        $line = [string]$_.CommandLine
        ($line -match '(?i)(editorial_daemon_v2|Run-V2-Editorial-Auto|recover_existing_chat_v2|incident_worker_v2)\.(py|ps1)') -or
        ($_.Name -ieq 'chrome.exe' -and $line.Contains($profile))
    })
}

if (-not (Test-Path -LiteralPath $profile -PathType Container)) {
    throw 'Chrome V2 autenticado no existe; no se hará ninguna modificación.'
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { throw 'Falta la tarea V2. Usar primero el instalador V2 habitual.' }
if (-not (Test-Path -LiteralPath $flag)) { throw 'Falta el control de ejecución de V2.' }
$previousFlag = (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim()
if ($previousFlag -ne 'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    throw 'El editor V2 no está habilitado; no se activará sin revisar su estado.'
}
$taskWasDisabled = ([string]$task.State -eq 'Disabled')
if ($taskWasDisabled) { throw 'La tarea V2 está deshabilitada; revisar antes de actualizar.' }

# Descargas verificadas, sin alterar todavía el consumidor instalado.
$infoUrl = 'https://api.github.com/repos/' + $repo + '/commits/' +
    [uri]::EscapeDataString($branch)
$head = Invoke-RestMethod -Uri $infoUrl -Headers $headers -TimeoutSec 20
$sha = [string]$head.sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub no confirmó la revisión V2.' }
$stage = Join-Path $root ('re-priority-stage-' + $sha.Substring(0,12))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$base = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/'
foreach ($file in $files) {
    $dest = Join-Path $stage $file
    Invoke-WebRequest -Uri ($base + $file) -OutFile $dest -Headers $headers -UseBasicParsing -TimeoutSec 35
    if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -lt 80) {
        throw ('Módulo descargado incompleto: ' + $file)
    }
}
$newDaemon = Get-Content -LiteralPath (Join-Path $stage 'editorial_daemon_v2.py') -Raw
if (-not $newDaemon.Contains('sync_private_re_v2.py')) {
    throw 'La revisión descargada aún no contiene el consumidor RE directo.'
}
$python = (Get-Command py.exe -ErrorAction Stop).Source
$savedPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $stage + ';' + $root
$stdOut = Join-Path $stage 'preflight.stdout.log'
$stdErr = Join-Path $stage 'preflight.stderr.log'
try {
    $test = Start-Process -FilePath $python -ArgumentList @('-3','-m','unittest','-v',
        'test_auto_editorial_v2','test_re_request_v2','test_sync_private_re_v2') `
        -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdOut -RedirectStandardError $stdErr
    if ($test.ExitCode -ne 0) {
        Get-Content -LiteralPath $stdErr -Tail 20 | ForEach-Object { Write-Host $_ }
        throw 'Las pruebas del nuevo consumidor RE han fallado. El editor actual sigue intacto.'
    }
} finally { $env:PYTHONPATH = $savedPythonPath }
Write-Host ('TT_V2_RE_STAGE_TESTS=OK sha=' + $sha.Substring(0,12))

# Pedir parada cooperativa del daemon: termina la ficha actual y sale del
# bucle sin cerrar Chrome ni interrumpir ningún trabajo ya enviado.
$activated = $false
$copied = $false
$backup = Join-Path $root ('re-priority-backup-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))
try {
    Flag 'TT_V2_AUTO_EDITORIAL_ENABLED=NO'
    Write-Host 'TT_V2_RE_WAITING_FOR_CURRENT_JOB=YES'
    $deadline = [DateTime]::UtcNow.AddMinutes($MaxWaitMinutes)
    $idleChecks = 0
    do {
        $active = @(V2ActiveProcesses)
        if ($active.Count -eq 0) { $idleChecks += 1 } else { $idleChecks = 0 }
        if ($idleChecks -ge 2) { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'Tiempo de espera agotado: el trabajo V2 sigue activo, no se han sustituido archivos.'
        }
        Start-Sleep -Seconds 8
    } while ($true)

    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($file in $files) {
        $original = Join-Path $root $file
        if (Test-Path -LiteralPath $original) {
            Copy-Item -LiteralPath $original -Destination (Join-Path $backup $file) -ErrorAction Stop
        }
    }
    # Activar el rollback ANTES de la primera sustitución: un error a mitad
    # de una copia también tiene que restaurar todos los módulos anteriores.
    $copied = $true
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $stage $file) -Destination (Join-Path $root $file) -Force -ErrorAction Stop
    }
    if (-not ((Get-Content -LiteralPath (Join-Path $root 'editorial_daemon_v2.py') -Raw).Contains('sync_private_re_v2.py'))) {
        throw 'No se verificó la instalación del consumidor RE.'
    }
    Flag 'TT_V2_AUTO_EDITORIAL_ENABLED=YES'
    $activated = $true
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Host 'TT_V2_RE_PRIORITY_INSTALLED=YES'
    Write-Host 'TT_V2_RE_PRIORITY_START_REQUESTED=YES'
    Write-Host ('TT_V2_RE_PRIORITY_BACKUP=' + $backup)
    Write-Host 'TT_V2_RE_PRIORITY_CHECK=Consultar daemon-status.json dentro de 1 minuto'
} catch {
    $errorMessage = $_.Exception.Message
    # Restaurar los originales solo si seguimos sin un proceso V2 activo.
    if ($copied -and -not $activated -and @(V2ActiveProcesses).Count -eq 0) {
        foreach ($file in $files) {
            $oldFile = Join-Path $backup $file
            if (Test-Path -LiteralPath $oldFile) {
                Copy-Item -LiteralPath $oldFile -Destination (Join-Path $root $file) -Force
            } else {
                $newFile = Join-Path $root $file
                if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force }
            }
        }
        Write-Host 'TT_V2_RE_ROLLBACK=OK'
    }
    if (-not $activated) { Flag $previousFlag }
    throw $errorMessage
}
