# Reparar UNICAMENTE restos de Chrome de la prueba headless V2 fallida.
# NUNCA cierra Chrome V1, ni tareas/colas V1, ni borra diarios editoriales.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$profile = Join-Path $root 'ChromeProfile'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$out = Join-Path $root 'install-headless.stdout.log'
$err = Join-Path $root 'install-headless.stderr.log'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (!$task -or $task.State -ne 'Disabled') {
    throw 'REPARACION BLOQUEADA: la tarea V2 debe estar Disabled'
}
if (!(Test-Path $flag) -or
    (Get-Content $flag -Raw -Encoding UTF8).Trim() -ne 'TT_V2_AUTO_EDITORIAL_ENABLED=NO') {
    throw 'REPARACION BLOQUEADA: el consumidor V2 no está deshabilitado'
}
$daemon = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    ($_.Name -match '^(python|pythonw|py)(\.exe)?$') -and
    $_.CommandLine -and $_.CommandLine.Contains('TTActualidadV2') -and
    $_.CommandLine.Contains('editorial_daemon_v2.py')
})
if ($daemon.Count -ne 0) { throw 'REPARACION BLOQUEADA: consumidor V2 aún activo' }
if (!(Test-Path $out) -or !(Test-Path $err)) {
    throw 'No se encontraron registros de prueba Chrome V2 fallida'
}
$logOut = Get-Item $out
$logErrText = Get-Content $err -Raw -Encoding UTF8
$logStd = Get-Content $out -Raw -Encoding UTF8
if (!$logErrText.Contains('TT_V2_HEADLESS_PREFLIGHT_ERROR=') -or
    !$logStd.Contains('TT_V2_HEADLESS_MESSAGE_SENT=NO')) {
    throw 'No está acreditado que el Chrome pendiente proceda de prueba sin envíos'
}
# Las redirecciones pueden reutilizar archivos: usar LastWriteTime, nunca
# CreationTime, para estimar la ventana de la última prueba.
$earliest = $logOut.LastWriteTime.AddMinutes(-5)

function Get-ProfileV2Chrome {
    $prefix = '--user-data-dir=' + $profile
    @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and
            $_.CommandLine.IndexOf($prefix,
              [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

$stale = @(Get-ProfileV2Chrome)
foreach ($process in $stale) {
    if (!$process.CreationDate -or ([datetime]$process.CreationDate) -lt $earliest) {
        throw ('REPARACION BLOQUEADA: Chrome V2 antiguo no atribuible a preflight: PID ' +
               $process.ProcessId)
    }
}
Write-Host ('TT_V2_STALE_HEADLESS_PIDS=' + $stale.Count)
$quiet = 0
for ($round = 1; $round -le 18; $round++) {
    $live = @(Get-ProfileV2Chrome)
    foreach ($process in $live) {
        if (!$process.CreationDate -or ([datetime]$process.CreationDate) -lt $earliest) {
            throw ('REPARACION BLOQUEADA: Chrome V2 ajeno a prueba: PID ' +
                   $process.ProcessId)
        }
    }
    if ($live.Count -eq 0) {
        $quiet++
        if ($quiet -ge 2) { break }
    } else {
        $quiet=0
        foreach ($process in $live) {
            # Solo chrome.exe del user-data-dir exacto V2, creado después
            # del comienzo de la prueba que NO envió mensajes.
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 1
}
if (@(Get-ProfileV2Chrome).Count -gt 0 -or $quiet -lt 2) {
    throw 'Quedan procesos Chrome V2: no reinstalar ni reactivar'
}
Write-Host 'TT_V2_STALE_HEADLESS_CLEANED=YES'
Write-Host 'TT_V1_PROCESSES_TOUCHED=NO'

# Descargar el instalador actualizado y ejecutar nueva instalación.
$repo = 'fabricelop/europapress-rss'
$branch = 'feature/ttactualidad-v2-clean'
$headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='TTActualidadV2-safe-repair' }
$head = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo +
    '/commits/' + [Uri]::EscapeDataString($branch)) -Headers $headers -UseBasicParsing
$sha = [string]$head.sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'No se pudo verificar commit V2' }
$installer = Join-Path $root 'Install-V2-Editorial-Auto.ps1'
$download = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/Install-V2-Editorial-Auto.ps1'
Invoke-WebRequest -Uri $download -OutFile $installer -Headers $headers -UseBasicParsing
Write-Host ('TT_V2_REPAIR_COMMIT=' + $sha)
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installOut = Join-Path $root 'repair-install.stdout.log'
$installErr = Join-Path $root 'repair-install.stderr.log'
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $installer + '"'))
$reinstalled = Start-Process -FilePath $ps -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $installOut -RedirectStandardError $installErr
if (Test-Path $installOut) { Get-Content $installOut | ForEach-Object { Write-Host $_ } }
if ($reinstalled.ExitCode -ne 0) {
    if (Test-Path $installErr) { Get-Content $installErr -Tail 20 | ForEach-Object { Write-Host $_ } }
    throw ('Instalación V2 detenida con código ' + $reinstalled.ExitCode + '; tarea desactivada')
}
Write-Host 'TT_V2_HIDDEN_REPAIR_INSTALLED=YES'
Write-Host 'TT_V2_PUBLICATION=NO'
