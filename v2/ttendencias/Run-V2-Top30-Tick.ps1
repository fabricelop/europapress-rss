# TTActualidad V2: runner silencioso del trigger trimestral de hora.
# No abre Chrome, no publica, no toca V1.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$logdir = Join-Path $root 'logs-top30'
New-Item -ItemType Directory -Path $logdir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $logdir ("top30-" + $stamp + ".out.log")
$err = Join-Path $logdir ("top30-" + $stamp + ".err.log")
$script = Join-Path $root 'top30_tick_v2.py'
if (!(Test-Path -LiteralPath $script)) { throw "Falta $script" }
$launcher = (Get-Command py.exe -ErrorAction Stop).Source
$argline = '-3 "' + $script + '" --tick'
$process = Start-Process -FilePath $launcher -ArgumentList $argline -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
if ($process.ExitCode -ne 0) { throw ("TT_V2_TOP30_TICK_EXIT_CODE=" + $process.ExitCode + " (ver " + $err + ")") }
# Máximo 500 ficheros de log de usuario, sin acumular indefinidamente.
Get-ChildItem -LiteralPath $logdir -File -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 500 | Remove-Item -Force -ErrorAction SilentlyContinue
