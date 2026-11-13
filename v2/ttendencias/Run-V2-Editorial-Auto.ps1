# TTActualidad V2 - runner robusto: recuperar chat interrumpido y seguir.
# No modifica V1, perfiles 9223/9234, ni publica.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$daemon = Join-Path $root 'editorial_daemon_v2.py'
$recovery = Join-Path $root 'recover_existing_chat_v2.py'
$logDir = Join-Path $root 'editorial-auto-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if (!(Test-Path -LiteralPath $daemon) -or !(Test-Path -LiteralPath $recovery)) {
    throw 'Faltan los módulos V2 del consumidor y rescate'
}
if (!(Test-Path -LiteralPath $flag) -or
    (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() -ne
    'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    Write-Host 'TT_V2_AUTO_ENABLED=NO'
    exit 0
}
$py = (Get-Command py.exe -ErrorAction Stop).Source
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$recoverOut = Join-Path $logDir ('recover-' + $stamp + '.stdout.log')
$recoverErr = Join-Path $logDir ('recover-' + $stamp + '.stderr.log')
$daemonOut = Join-Path $logDir ('auto-' + $stamp + '.log')
$daemonErr = Join-Path $logDir ('auto-' + $stamp + '.stderr.log')
Write-Host ('TT_V2_AUTO_LOG=' + $daemonOut)
# Si Windows mató al consumidor dejando Chrome V2 abierto, rescatar el
# chat ya enviado. Nunca continuar con un Chrome huérfano no identificado.
$proc = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $recovery + '"'), '--auto') `
    -PassThru -Wait -NoNewWindow -RedirectStandardOutput $recoverOut -RedirectStandardError $recoverErr
if (Test-Path -LiteralPath $recoverOut) {
    Get-Content -LiteralPath $recoverOut | ForEach-Object { Write-Host $_ }
}
if ($proc.ExitCode -ne 0) {
    Write-Host 'TT_V2_AUTO_RECOVERY=BLOCKED_NO_RESEND'
    if (Test-Path -LiteralPath $recoverErr) {
        Get-Content -LiteralPath $recoverErr -Tail 12 | ForEach-Object { Write-Host $_ }
    }
    throw ('Falló recuperación del chat V2 previo. No se ha enviado otra vez. Código ' + $proc.ExitCode)
}
# stdout/stderr a ficheros independientes, sin pipe Tee-Object de larga duración.
# Las tareas con CTRL+C/terminal roto no deben perder el chat por cerrar un pipe.
Write-Host 'TT_V2_AUTO_RECOVERY=OK'
$worker = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $daemon + '"'),
    '--run', '--poll-seconds', '90') -PassThru -Wait -NoNewWindow `
    -RedirectStandardOutput $daemonOut -RedirectStandardError $daemonErr
if ($worker.ExitCode -ne 0) {
    Write-Host ('TT_V2_AUTO_WORKER_EXIT=' + $worker.ExitCode)
    if (Test-Path -LiteralPath $daemonErr) {
        Get-Content -LiteralPath $daemonErr -Tail 15 | ForEach-Object { Write-Host $_ }
    }
    throw ('Consumidor V2 detenido. El programador reintentará y recuperará el chat si quedó abierto.')
}
Write-Host 'TT_V2_AUTO_RUNNER_EXIT=0'
