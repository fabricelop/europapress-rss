# V2: tarea SOLO imágenes. No espera al consumidor editorial.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$flag = Join-Path $root 'auto-images-v2.enabled'
$script = Join-Path $root 'image_daemon_v2.py'
if (!(Test-Path -LiteralPath $script)) { throw 'Falta image_daemon_v2.py' }
if (!(Test-Path -LiteralPath $flag) -or (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() -ne 'TT_V2_AUTO_IMAGES_ENABLED=YES') {
    Write-Host 'TT_V2_IMAGES_AUTO_ENABLED=NO'
    exit 0
}
$env:TT_V2_IMAGE_CHROME_HEADLESS = '0'
$py = (Get-Command py.exe -ErrorAction Stop).Source
$logs = Join-Path $root 'image-only-logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdout = Join-Path $logs ('auto-' + $stamp + '.log')
$stderr = Join-Path $logs ('auto-' + $stamp + '.stderr.log')
$p = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $script + '"'), '--run', '--poll-seconds', '90') -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if ($p.ExitCode -ne 0) {
    if (Test-Path $stderr) { Get-Content -LiteralPath $stderr -Tail 20 }
    throw ('V2 images daemon failed (exit ' + $p.ExitCode + ')')
}
