# V2 imágenes independientes. Por defecto prepara piloto, NO activa tarea.
param([switch]$EnableImages)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Images-Auto'
$branch = 'feature/ttactualidad-v2-clean'
$repo = 'fabricelop/europapress-rss'
if (!(Test-Path -LiteralPath (Join-Path $root 'editorial_run_v2.py'))) {
    throw 'Instala primero V2 editorial (aislamiento de perfiles)'
}
$old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($old -and $old.State -eq 'Running') {
    throw 'Consumidor de imágenes V2 activo: esperar a que termine antes de reemplazar su código'
}
$headers = @{ 'User-Agent'='TTActualidadV2-images-installer'; 'Accept'='application/vnd.github+json' }
$commitUrl = 'https://api.github.com/repos/' + $repo + '/commits/' + [Uri]::EscapeDataString($branch)
$sha = [string](Invoke-RestMethod -Uri $commitUrl -Headers $headers -UseBasicParsing).sha
if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'No se pudo fijar revisión V2' }
$base = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/'
$files = @(
    'image_target_tracker_v2.py',
    'image_worker_v2.py',
    'image_daemon_v2.py',
    'image_intake_v2.py',
    'image_job_v2.py',
    'image_same_chat_v2.py',
    'image_github_v2.py',
    'test_image_worker_v2.py',
    'test_image_same_chat_v2.py',
    'test_image_github_v2.py',
    'Run-V2-Image-One.ps1',
    'Run-V2-Images-Auto.ps1',
    'Setup-V2-Image-Chrome-Login.ps1'
)
foreach ($file in $files) {
    $path = Join-Path $root $file
    Invoke-WebRequest -Uri ($base + $file) -UseBasicParsing -Headers $headers -OutFile $path
    if (!(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -lt 50) {
        throw ('Módulo V2 de imágenes no descargado: ' + $file)
    }
}
$py = (Get-Command py.exe -ErrorAction Stop).Source
$stdout = Join-Path $root 'install-image-tests.stdout.log'
$stderr = Join-Path $root 'install-image-tests.stderr.log'
foreach ($name in @('test_image_worker_v2.py','test_image_same_chat_v2.py','test_image_github_v2.py')) {
    $script = Join-Path $root $name
    $p = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $script + '"')) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($p.ExitCode -ne 0) {
        if (Test-Path $stderr) { Get-Content -LiteralPath $stderr -Tail 30 }
        throw ('Image tests failed: ' + $name)
    }
    Write-Host ('TT_V2_IMAGES_TEST=OK:' + $name)
}
$profile = Join-Path $root 'ChromeProfileImages'
if ($EnableImages -and !(Test-Path -LiteralPath $profile -PathType Container)) {
    throw 'Primero ejecutar Setup-V2-Image-Chrome-Login.ps1 (perfil distinto al editorial)'
}
$flag = Join-Path $root 'auto-images-v2.enabled'
$value = 'TT_V2_AUTO_IMAGES_ENABLED=NO'
if ($EnableImages) { $value = 'TT_V2_AUTO_IMAGES_ENABLED=YES' }
[IO.File]::WriteAllText($flag, $value + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$runner = Join-Path $root 'Run-V2-Images-Auto.ps1'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $account),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 3650))
)
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
if ($EnableImages) {
    Start-ScheduledTask -TaskName $taskName
    Write-Host 'TT_V2_IMAGES_AUTO=ENABLED'
} else {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Write-Host 'TT_V2_IMAGES_AUTO=DISABLED_PILOT_ONLY'
}
Write-Host ('TT_V2_IMAGE_INSTALL_COMMIT=' + $sha)
Write-Host 'TT_V2_EDITORIAL_AUTO=UNTOUCHED'
Write-Host 'TT_V2_IMAGE_CHROME_PROFILE=INDEPENDENT'
Write-Host 'TT_V2_IMAGE_PUBLICATION=NO'
