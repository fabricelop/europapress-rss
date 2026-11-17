# TTActualidad V2 - runner robusto: chats nuevos por revision, sin abrir chats fallidos.
# No modifica V1, perfiles 9223/9234, ni publica.
# Reutiliza el patron V1 de procesos ocultos con salida a logs independientes.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$daemon = Join-Path $root 'editorial_daemon_v2.py'
$logDir = Join-Path $root 'editorial-auto-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if (!(Test-Path -LiteralPath $daemon)) {
    throw 'Falta el módulo V2 del consumidor'
}
if (!(Test-Path -LiteralPath $flag) -or
    (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() -ne
    'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    Write-Host 'TT_V2_AUTO_ENABLED=NO'
    exit 0
}
# The V2 Chrome must be normal headed but hidden, not headless.
$env:TT_V2_CHROME_HEADLESS = '0'
$py = (Get-Command py.exe -ErrorAction Stop).Source
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$daemonOut = Join-Path $logDir ('auto-' + $stamp + '.log')
$daemonErr = Join-Path $logDir ('auto-' + $stamp + '.stderr.log')
Write-Host ('TT_V2_AUTO_LOG=' + $daemonOut)
Write-Host 'TT_V2_POWERSHELL_HIDDEN=YES'
# El daemon/incident_worker comprueba diarios, leases y perfiles Chrome
# antes de iniciar una nueva revision. Nunca abrir una URL de chat anterior
# al reiniciar el runner, aunque un proceso previo hubiera quedado a medias.
# stdout/stderr a ficheros independientes, sin pipe Tee-Object de larga duración.
# Las tareas con CTRL+C/terminal roto no deben perder el chat por cerrar un pipe.
Write-Host 'TT_V2_AUTO_PREVIOUS_CHAT_REUSE=DISABLED'
$worker = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $daemon + '"'),
    '--run', '--poll-seconds', '90') -PassThru -Wait -WindowStyle Hidden `
    -RedirectStandardOutput $daemonOut -RedirectStandardError $daemonErr
if ($worker.ExitCode -ne 0) {
    Write-Host ('TT_V2_AUTO_WORKER_EXIT=' + $worker.ExitCode)
    if (Test-Path -LiteralPath $daemonErr) {
        Get-Content -LiteralPath $daemonErr -Tail 15 | ForEach-Object { Write-Host $_ }
    }
    throw ('Consumidor V2 detenido. El programador reintentará sin reabrir chats anteriores.')
}
Write-Host 'TT_V2_AUTO_RUNNER_EXIT=0'
