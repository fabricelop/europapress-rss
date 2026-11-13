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
# Impedir que el programador reinicie una instancia vieja a mitad del cambio.
if ($existing) {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Write-Host 'TT_V2_OLD_TASK_TEMPORARILY_DISABLED=YES'
}
$flag = Join-Path $root 'auto-editorial-v2.enabled'
[IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=NO" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false)))

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
    'chrome_command_v2.py',
    'headless_preflight_v2.py',
    'incident_retry_v2.py',
    'incident_worker_v2.py',
    'test_incident_retry_v2.py',
    'test_chrome_command_v2.py',
    'recover_existing_chat_v2.py',
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
# Las pruebas unittest muestran puntos por stderr aun cuando son correctas.
# Windows PowerShell 5.1 + ErrorActionPreference=Stop convierte ese stderr
# en NativeCommandError. Capturar ambos canales y comprobar el exit code REAL.
$py = (Get-Command py.exe -ErrorAction Stop).Source
$testFile = Join-Path $root 'test_auto_editorial_v2.py'
$testStdout = Join-Path $root 'install-auto-tests.stdout.log'
$testStderr = Join-Path $root 'install-auto-tests.stderr.log'
$test = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $testFile + '"')) `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $testStdout -RedirectStandardError $testStderr
if (Test-Path $testStdout) { Get-Content -LiteralPath $testStdout | ForEach-Object { Write-Host $_ } }
if (Test-Path $testStderr) { Get-Content -LiteralPath $testStderr | ForEach-Object { Write-Host $_ } }
if ($test.ExitCode -ne 0) {
    throw ('No superó las pruebas de seguridad V2 (exit ' + $test.ExitCode + '). Ver ' + $testStderr)
}
Write-Host 'TT_V2_AUTO_TESTS=OK'
foreach ($suite in @('test_chrome_command_v2.py','test_incident_retry_v2.py')) {
    $testPath = Join-Path $root $suite
    $result = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $testPath + '"')) `
        -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $testStdout -RedirectStandardError $testStderr
    if ($result.ExitCode -ne 0) {
        if (Test-Path $testStderr) { Get-Content $testStderr -Tail 20 | ForEach-Object { Write-Host $_ } }
        throw ('Pruebas V2 no superadas: ' + $suite)
    }
    Write-Host ('TT_V2_TEST_SUITE_OK=' + $suite)
}
# Preflight de Playwright, sin abrir Chrome, capturando stderr igualmente.
$checkStdout = Join-Path $root 'install-auto-check.stdout.log'
$checkStderr = Join-Path $root 'install-auto-check.stderr.log'
$check = Start-Process -FilePath $py -ArgumentList @('-3', '-c', '"import playwright.sync_api"') `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $checkStdout -RedirectStandardError $checkStderr
if ($check.ExitCode -ne 0) {
    if (Test-Path $checkStderr) { Get-Content -LiteralPath $checkStderr | ForEach-Object { Write-Host $_ } }
    throw ('Playwright no disponible para Chrome V2 (exit ' + $check.ExitCode + ')')
}
Write-Host 'TT_V2_PLAYWRIGHT=READY'

# Las pruebas anteriores ya utilizaron un perfil Chrome V2 autenticado.
# No habilitar envíos automáticos si ese perfil no existe.
$profile = Join-Path $root 'ChromeProfile'
if (!(Test-Path -LiteralPath $profile -PathType Container)) {
    throw 'No hay perfil Chrome V2. Probar primero la elaboración individual autenticada.'
}

# Primero recuperar el chat V2 que ya se envió si Windows cortó el
# consumidor. No reenviar Jordi Wild, no cerrar un Chrome V2 sin captura.
$recover = Join-Path $root 'recover_existing_chat_v2.py'
$recoverOut = Join-Path $root 'install-auto-recovery.stdout.log'
$recoverErr = Join-Path $root 'install-auto-recovery.stderr.log'
$recovered = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $recover + '"'), '--auto') `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $recoverOut -RedirectStandardError $recoverErr
if (Test-Path -LiteralPath $recoverOut) {
    Get-Content -LiteralPath $recoverOut | ForEach-Object { Write-Host $_ }
}
if ($recovered.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $recoverErr) {
        Get-Content -LiteralPath $recoverErr -Tail 14 | ForEach-Object { Write-Host $_ }
    }
    throw 'Recuperación de chat V2 bloqueada: tarea seguirá desactivada, sin reenvíos ni borrados'
}
Write-Host 'TT_V2_EXISTING_CHAT_RECOVERY=OK'
$headless = Join-Path $root 'headless_preflight_v2.py'
$headlessOut = Join-Path $root 'install-headless.stdout.log'
$headlessErr = Join-Path $root 'install-headless.stderr.log'
$headlessResult = Start-Process -FilePath $py -ArgumentList @('-3', ('"' + $headless + '"')) `
    -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $headlessOut -RedirectStandardError $headlessErr
if (Test-Path $headlessOut) { Get-Content $headlessOut | ForEach-Object { Write-Host $_ } }
if ($headlessResult.ExitCode -ne 0) {
    if (Test-Path $headlessErr) { Get-Content $headlessErr -Tail 20 | ForEach-Object { Write-Host $_ } }
    throw 'Chrome V2 oculto no validado: consumidor seguirá desactivado, sin reenvíos'
}
Write-Host 'TT_V2_HEADLESS_VALIDATED=YES'
# La bandera exacta es autorización para abrir chats. Guardarla solo
# tras descargar/validar los módulos y justo antes de registrar la tarea.
$flag = Join-Path $root 'auto-editorial-v2.enabled'
[IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=YES" + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$runner = Join-Path $root 'Run-V2-Editorial-Auto.ps1'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $account
# Además del inicio de sesión, rearmar cada 3 minutos: la última
# instalación quedó en Ready tras un cierre inesperado de Windows.
$repeatStart = (Get-Date).AddMinutes(3)
$repeatTrigger = New-ScheduledTaskTrigger -Once -At $repeatStart `
    -RepetitionInterval (New-TimeSpan -Minutes 3) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$triggers = @($logonTrigger, $repeatTrigger)
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Disabled') { throw 'Tarea V2 quedó desactivada' }
Write-Host ('TT_V2_INSTALL_COMMIT=' + $sha)
Write-Host 'TT_V2_AUTO_TASK_REGISTERED=YES'
Write-Host 'TT_V2_AUTO_SELF_HEAL_EVERY_MINUTES=3'
Write-Host 'TT_V2_AUTO_ENABLED=YES'
Write-Host 'TT_V2_AUTO_PUBLICATION=NO'
Write-Host ('TT_V2_AUTO_TASK_NAME=' + $taskName)
Write-Host 'TT_V2_AUTO_CHROME_VISIBLE=NO'
Write-Host 'TT_V2_AUTO_CHROME_HEADLESS=YES'
Write-Host 'TT_V2_AUTO_POWERSHELL_HIDDEN=YES'
# Inicio inmediato en esta sesión, no hay que cerrar y abrir Windows.
Start-ScheduledTask -TaskName $taskName
Write-Host 'TT_V2_AUTO_START_REQUESTED=YES'
Write-Host ('TT_V2_AUTO_LOG_DIR=' + (Join-Path $root 'editorial-auto-logs'))
