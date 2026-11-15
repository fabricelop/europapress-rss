# Actualización única de V2 editorial + imágenes. NO toca V1 ni publicaciones.
# Se ejecuta una sola vez con PowerShell; las tareas y sus Chrome quedan ocultos.
param([ValidateRange(1, 60)][int]$WaitMinutes = 25)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$tasks = @('TTActualidadV2-Editorial-Auto', 'TTActualidadV2-Images-Auto')
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (!(Test-Path -LiteralPath $root -PathType Container)) {
    throw 'V2 no instalado en este usuario. Se requiere instalacion inicial V2.'
}

Write-Host 'TT_V2_UPGRADE=WAIT_FOR_EXISTING_CHATS'
foreach ($task in $tasks) {
    $old = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if ($old) {
        Disable-ScheduledTask -TaskName $task | Out-Null
    }
}
# El daemon consulta esta bandera al volver de su chat en curso: salida
# cooperativa, SIN Stop-Process, taskkill ni reenviar conversaciones.
[IO.File]::WriteAllText((Join-Path $root 'auto-editorial-v2.enabled'),
    'TT_V2_AUTO_EDITORIAL_ENABLED=NO' + [Environment]::NewLine, $utf8)
[IO.File]::WriteAllText((Join-Path $root 'auto-images-v2.enabled'),
    'TT_V2_AUTO_IMAGES_ENABLED=NO' + [Environment]::NewLine, $utf8)

$limit = (Get-Date).AddMinutes($WaitMinutes)
do {
    $busyTasks = @($tasks | Where-Object {
        $task = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
        $task -and $task.State -eq 'Running'
    })
    $v2Python = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.Name -in @('python.exe','pythonw.exe','py.exe') -and
            $_.CommandLine -and $_.CommandLine.Contains($root) -and
            $_.CommandLine -match '(editorial_daemon_v2|image_daemon_v2|editorial_run_v2|image_worker_v2)\.py'
        })
    $v2Chrome = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') -and
            ($_.CommandLine.Contains((Join-Path $root 'ChromeProfile')) -or
             $_.CommandLine.Contains((Join-Path $root 'ChromeProfileImages')))
        })
    if (!$busyTasks.Count -and !$v2Python.Count -and !$v2Chrome.Count) {
        break
    }
    Write-Host ('TT_V2_UPGRADE_WAIT tasks=' + $busyTasks.Count +
                ' python=' + $v2Python.Count + ' chrome=' + $v2Chrome.Count)
    if ((Get-Date) -ge $limit) {
        throw 'V2_UPGRADE_WAIT_TIMEOUT: dejar terminar los chats; NO se ha detenido ningun proceso ni instalado el codigo nuevo.'
    }
    Start-Sleep -Seconds 10
} while ($true)

$repo = 'fabricelop/europapress-rss'
$branch = 'feature/ttactualidad-v2-clean'
$api = 'https://api.github.com/repos/' + $repo + '/commits/' + [Uri]::EscapeDataString($branch)
$headers = @{ 'User-Agent' = 'TTActualidadV2-parallel-upgrader' }
$sha = [string](Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing).sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'No se pudo fijar el commit V2' }
$source = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias/'
$editorialInstaller = Join-Path $root 'Install-V2-Editorial-Auto.ps1'
$imageInstaller = Join-Path $root 'Install-V2-Images-Auto.ps1'
Invoke-WebRequest -Uri ($source + 'Install-V2-Editorial-Auto.ps1') -Headers $headers `
    -UseBasicParsing -OutFile $editorialInstaller
Invoke-WebRequest -Uri ($source + 'Install-V2-Images-Auto.ps1') -Headers $headers `
    -UseBasicParsing -OutFile $imageInstaller
Write-Host ('TT_V2_UPGRADE_PINNED_COMMIT=' + $sha)

# Los instaladores descargan y validan los módulos, prueban Playwright,
# y registran tareas wscript.exe //B con un único proceso gestor por tipo.
# Si algo falla, NO activar de nuevo a ciegas los servicios antiguos.
& $editorialInstaller
if (!$?) { throw 'V2_EDITORIAL_INSTALL_FAILED' }
& $imageInstaller -EnableImages
if (!$?) { throw 'V2_IMAGES_INSTALL_FAILED' }

foreach ($task in $tasks) {
    $installed = Get-ScheduledTask -TaskName $task -ErrorAction Stop
    if ($installed.State -eq 'Disabled') {
        throw ('V2_UPGRADE_TASK_DISABLED=' + $task)
    }
    if ($installed.Actions[0].Execute -notlike '*wscript.exe') {
        throw ('V2_UPGRADE_VISIBLE_LAUNCHER_BLOCKED=' + $task)
    }
}
Write-Host 'TT_V2_UPGRADE=INSTALLED_AND_STARTED_HIDDEN'
Write-Host 'TT_V2_EDITORIAL_PARALLEL_WORKERS=3'
Write-Host 'TT_V2_IMAGE_PARALLEL_WORKERS=2'
Write-Host 'TT_V2_PUBLICATION=NO'
