# TTActualidad V2: ejecutor editorial aislado, arranque de sesión Windows.
# SOLO el consumidor V2. No modifica ni arranca tareas de V1.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$script = Join-Path $root 'editorial_daemon_v2.py'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$logDir = Join-Path $root 'editorial-auto-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if (!(Test-Path -LiteralPath $script)) { throw "Falta el consumidor V2: $script" }
if (!(Test-Path -LiteralPath $flag)) {
    Write-Host 'TT_V2_AUTO_ENABLED=NO'
    exit 0
}
if ((Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() -ne 'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    Write-Host 'TT_V2_AUTO_ENABLED=NO'
    exit 0
}
$log = Join-Path $logDir ('auto-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Write-Host ('TT_V2_AUTO_LOG=' + $log)
# Chrome permanece visible durante desarrollo; un solo chat y proceso
# de Chrome V2 a la vez; se cierra al terminar el trabajo.
$ErrorActionPreference = 'Continue'
& py.exe -3 $script --run --poll-seconds 90 2>&1 | Tee-Object -FilePath $log -Append
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($exitCode -ne 0) { throw ('Consumidor V2 terminó con exit=' + $exitCode + '; ver ' + $log) }
Write-Host 'TT_V2_AUTO_RUNNER_EXIT=0'
