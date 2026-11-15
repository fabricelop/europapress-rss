# Piloto manual y aislado TTActualidad V2: comprueba el Top30 y, opcionalmente,
# ejecuta exactamente una tendencia con texto + ImageGen en una sola sesion Chrome.
# Nunca activa el programador, publica ni modifica V1 o Cloudflare.
param([switch]$RunOne)

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$runner = Join-Path $root 'editorial_run_v2.py'
$image = Join-Path $root 'image_same_chat_v2.py'
$githubImage = Join-Path $root 'image_github_v2.py'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$taskName = 'TTActualidadV2-Editorial-Auto'

foreach ($file in @($runner, $image, $githubImage)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw ('Falta archivo de V2: ' + $file + '. Instala con -PilotOnly primero.')
    }
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and $task.State -ne 'Disabled') {
    throw ('El programador V2 esta ' + $task.State + '. Piloto cancelado para impedir concurrencia.')
}
if ((Test-Path -LiteralPath $flag) -and
    (Get-Content -LiteralPath $flag -Raw) -match 'TT_V2_AUTO_EDITORIAL_ENABLED=YES') {
    throw 'Bandera editorial automatica V2 habilitada; piloto cancelado.'
}

# No intervenir sobre ningun proceso, ni siquiera sobre otro Chrome V2.
$v2Processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -match '^(python|pythonw|py|chrome)\.exe$' -and
    $_.CommandLine -and
    ($_.CommandLine -match 'editorial_(daemon|run)_v2\.py' -or
     $_.CommandLine.Contains('--user-data-dir=') -and
     $_.CommandLine.Contains((Join-Path $root 'ChromeProfile')))
})
if ($v2Processes.Count -gt 0) {
    throw 'Existe otro Python/Chrome de V2. No abrir otro chat ni forzar cierre.'
}

$py = (Get-Command py.exe -ErrorAction Stop).Source
$logDir = Join-Path $root 'pilot-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdout = Join-Path $logDir ('pilot-' + $stamp + '.stdout.log')
$stderr = Join-Path $logDir ('pilot-' + $stamp + '.stderr.log')

function Invoke-V2PilotPython([string[]]$extra) {
    $arguments = @('-3', ('"' + $runner + '"')) + $extra
    $p = Start-Process -FilePath $py -ArgumentList $arguments -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
    if (Test-Path -LiteralPath $stdout) {
        Get-Content -LiteralPath $stdout | ForEach-Object { Write-Host $_ }
    }
    if (Test-Path -LiteralPath $stderr) {
        Get-Content -LiteralPath $stderr | ForEach-Object { Write-Host $_ }
    }
    if ($p.ExitCode -ne 0) {
        throw ('TT_V2_PILOT_EXIT=' + $p.ExitCode + '. Logs: ' + $logDir)
    }
}

Write-Host 'TT_V2_PILOT_AUTO_DISABLED=YES'
Write-Host 'TT_V2_PILOT_CLOUDFLARE_DEPLOY=NO'
Write-Host 'TT_V2_PILOT_PUBLICATION=NO'
Write-Host 'TT_V2_PILOT_PHASE=PREFLIGHT_TOP30'
Invoke-V2PilotPython -extra @('--next')
$preflightText = Get-Content -LiteralPath $stdout -Raw
if ($preflightText -notmatch 'TT_V2_PREFLIGHT=YES') {
    Write-Host 'TT_V2_PILOT_NO_ELIGIBLE_OR_STALE=YES'
    Write-Host 'No se enviaron mensajes ni se genero ninguna imagen.'
    return
}
if (-not $RunOne) {
    Write-Host 'TT_V2_PILOT_DRY_RUN=YES'
    Write-Host 'Para procesar una unica tendencia, repite con -RunOne.'
    return
}

Write-Host 'TT_V2_PILOT_PHASE=ONE_TREND_TEXT_AND_IMAGE'
# --next --run vuelve a validar la seleccion inmediatamente antes del envio.
# Solo se invoca UNA vez; no hay reintentos si ChatGPT o GitHub fallan.
Invoke-V2PilotPython -extra @('--next', '--run')
$resultText = Get-Content -LiteralPath $stdout -Raw
if ($resultText -notmatch 'TT_V2_GITHUB_VERIFIED=YES' -or
    $resultText -notmatch 'TT_V2_IMAGE_SAVED_IN_SAME_CHAT=YES_GITHUB' -or
    $resultText -notmatch 'TT_V2_REMAINING_PROCESSES=0') {
    throw ('V2 texto/imagen/cierre sin verificacion completa. Revisar logs: ' + $logDir)
}
Write-Host 'TT_V2_PILOT_ONE_TREND_TEXT_IMAGE_CHROME_CLOSED=YES'
Write-Host ('TT_V2_PILOT_LOG_DIR=' + $logDir)
