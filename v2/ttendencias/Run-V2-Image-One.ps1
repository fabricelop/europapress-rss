# V2: solo UNA imagen desde Top30, con su propio Chrome.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$script = Join-Path $root 'image_worker_v2.py'
if (!(Test-Path -LiteralPath $script)) { throw 'Instala primero el consumidor V2 de imágenes' }
$py = (Get-Command py.exe -ErrorAction Stop).Source
$logs = Join-Path $root 'image-only-logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdout = Join-Path $logs ('one-' + $stamp + '.log')
$stderr = Join-Path $logs ('one-' + $stamp + '.stderr.log')
$p = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $script + '"'), '--run-one') -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if (Test-Path $stdout) { Get-Content -LiteralPath $stdout }
if (Test-Path $stderr) { Get-Content -LiteralPath $stderr }
if ($p.ExitCode -ne 0) { throw ('V2 imagen individual falló (exit ' + $p.ExitCode + '); ver ' + $stderr) }
Write-Host 'TT_V2_IMAGE_ONE_DONE=YES'
Write-Host 'TT_V2_IMAGE_PUBLICATION=NO'
