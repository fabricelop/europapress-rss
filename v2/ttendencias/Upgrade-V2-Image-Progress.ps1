# TTActualidad V2: actualizar solo la señal de progreso de imágenes.
# No reinicia tareas, no cierra Chrome, no toca V1 ni publica contenido.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
if (!(Test-Path -LiteralPath $root -PathType Container)) { throw 'TT_V2_NOT_INSTALLED' }
$repo = 'fabricelop/europapress-rss'
$branch = 'feature/ttactualidad-v2-clean'
$headers = @{ 'User-Agent'='TTActualidadV2-image-progress-updater' }
$refUrl = 'https://api.github.com/repos/' + $repo + '/commits/' + [Uri]::EscapeDataString($branch)
$sha = [string](Invoke-RestMethod -Uri $refUrl -Headers $headers -UseBasicParsing).sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'TT_V2_REF_NOT_VERIFIED' }
$base = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/'
$files = @('web_top30_v2.py','image_worker_v2.py')
$temps = @{}
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
try {
    # Descargar y validar AMBOS antes de reemplazar ninguno.
    foreach ($name in $files) {
        $target = Join-Path $root $name
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw ('TT_V2_MODULE_MISSING=' + $name) }
        $staging = Join-Path $root ($name + '.incoming-' + [Guid]::NewGuid().ToString('N'))
        $temps[$name] = $staging
        Invoke-WebRequest -Uri ($base + $name) -Headers $headers -UseBasicParsing -OutFile $staging
        if ((Get-Item -LiteralPath $staging).Length -lt 2000) { throw ('TT_V2_DOWNLOAD_INVALID=' + $name) }
        $source = [IO.File]::ReadAllText($staging)
        if ($name -eq 'image_worker_v2.py' -and !$source.Contains('def update_image_progress(')) {
            throw 'TT_V2_IMAGE_PROGRESS_WORKER_MISSING'
        }
        if ($name -eq 'web_top30_v2.py' -and !$source.Contains('def live_image_progress_for_revision(')) {
            throw 'TT_V2_IMAGE_PROGRESS_PROJECTION_MISSING'
        }
        $python = (Get-Command py.exe -ErrorAction Stop).Source
        $stdout = Join-Path $root 'image-progress-check.stdout.log'
        $stderr = Join-Path $root 'image-progress-check.stderr.log'
        $check = Start-Process -FilePath $python -ArgumentList @('-3','-m','py_compile',('"' + $staging + '"')) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($check.ExitCode -ne 0) { throw ('TT_V2_PYTHON_SYNTAX_FAILED=' + $name) }
    }
    foreach ($name in $files) {
        $target = Join-Path $root $name
        $backup = $target + '.backup-' + $stamp
        [IO.File]::Replace($temps[$name], $target, $backup)
    }
    [IO.File]::WriteAllText((Join-Path $root 'image-progress-upgrade-status.txt'),
        'TT_V2_IMAGE_PROGRESS_INSTALLED=YES' + [Environment]::NewLine +
        'TT_V2_PINNED_COMMIT=' + $sha + [Environment]::NewLine +
        'TT_V2_EXISTING_TASKS=UNTOUCHED' + [Environment]::NewLine +
        'TT_V2_CHROME_AND_CONSOLES=HIDDEN' + [Environment]::NewLine +
        'TT_V2_PUBLICATION=NO' + [Environment]::NewLine)
} finally {
    foreach ($staging in $temps.Values) {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}
