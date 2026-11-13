# Installer V2: consumidor editorial automático al iniciar sesión Windows.
# SOLO escribe en %LOCALAPPDATA%\TTActualidadV2 y crea su propia tarea.
# No modifica V1, puertos 9223/9234, main, Cloudflare ni publicaciones.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$branch = 'feature/ttactualidad-v2-clean'
$repo = 'fabricelop/europapress-rss'
$commitUrl = 'https://api.github.com/repos/' + $repo + '/commits/' + [Uri]::EscapeDataString($branch)
New-Item -ItemType Directory -Path $root -Force | Out-Null

# Un instalador nunca reemplaza ficheros mientras el consumidor está vivo.
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    throw 'Consumidor V2 activo. Desactivarlo y dejar que termine antes de actualizar.'
}
if (!(Get-Command py.exe -ErrorAction SilentlyContinue)) { throw 'Falta py.exe' }
if (!(Get-Command gh.exe -ErrorAction SilentlyContinue) -and
    -not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) {
    throw 'Se necesita gh auth o GH_TOKEN para GitHub V2'
}

$headers = @{ 'User-Agent' = 'TTActualidadV2-installer'; 'Accept'='application/vnd.github+json' }
$head = Invoke-RestMethod -Uri $commitUrl -Headers $headers -UseBasicParsing
$sha = [string]$head.sha
if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'No se pudo fijar commit V2' }
$base = 'https://raw.githubusercontent.com/' + $repo + '/' + $sha + '/v2/ttendencias'
$files = @(
    'editorial_daemon_v2.py',
    'auto_editorial_policy_v2.py',
    'select_current_top30_v2.py',
    'process_lock_v2.py',
    'batch_contract_v2.py',
    'editorial_batch_v2.py',
    'editorial_run_v2.py',
    'persist_capture_github.py',
    'editorial_capture_state.py',
    'chatgpt_transcript.py',
    'chatgpt_target_tracker.py',
    'web_top30_v2.py',
    'listas_v2.py',
    'test_auto_editorial_v2.py',
    'Run-V2-Editorial-Auto.ps1',
    'Disable-V2-Editorial-Auto.ps1'
)
foreach ($file in $files) {
    $target = Join-Path $root $file
    Invoke-WebRequest -Uri ($base + '/' + $file) -OutFile $target -UseBasicParsing -Headers $headers
    if (!(Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -lt 50) {
        throw 'Descarga V2 inválida: ' + $file
    }
}
# Probar selector y exclusión sin mandar mensajes.
& py.exe -3 (Join-Path $root 'test_auto_editorial_v2.py')
if ($LASTEXITCODE -ne 0) { throw 'No superó las pruebas de seguridad V2' }
# Preflight de Playwright, sin abrir Chrome.
& py.exe -3 -c 'import playwright.sync_api'
if ($LASTEXITCODE -ne 0) { throw 'Playwright no disponible para Chrome V2' }
Write-Host 'TT_V2_PLAYWRIGHT=READY'

# Las pruebas anteriores ya utilizaron un perfil Chrome V2 autenticado.
# No habilitar envíos automáticos si ese perfil no existe.
$profile = Join-Path $root 'ChromeProfile'
if (!(Test-Path -LiteralPath $profile -PathType Container)) {
    throw 'No hay perfil Chrome V2. Probar primero la elaboración individual autenticada.'
}

# La bandera exacta es autorización para abrir chats. Guardarla solo
# tras descargar/validar los módulos y justo antes de registrar la tarea.
$flag = Join-Path $root 'auto-editorial-v2.enabled'
[IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=YES" + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$runner = Join-Path $root 'Run-V2-Editorial-Auto.ps1'
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Disabled') { throw 'Tarea V2 quedó desactivada' }
Write-Host ('TT_V2_INSTALL_COMMIT=' + $sha)
Write-Host 'TT_V2_AUTO_TASK_REGISTERED=YES'
Write-Host 'TT_V2_AUTO_ENABLED=YES'
Write-Host 'TT_V2_AUTO_PUBLICATION=NO'
Write-Host ('TT_V2_AUTO_TASK_NAME=' + $taskName)
Write-Host 'TT_V2_AUTO_CHROME_VISIBLE=YES'
# Inicio inmediato en esta sesión, no hay que cerrar y abrir Windows.
Start-ScheduledTask -TaskName $taskName
Write-Host 'TT_V2_AUTO_START_REQUESTED=YES'
Write-Host ('TT_V2_AUTO_LOG_DIR=' + (Join-Path $root 'editorial-auto-logs'))
