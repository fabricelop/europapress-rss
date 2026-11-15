# V2: one controlled full editorial + ImageGen run; no V1/Worker/R2/publication.
# Explicit -RunOne is required. Existing V2 automation is paused gracefully:
# the current job finishes, then only one new pilot trend is started.
param([switch]$RunOne)

$ErrorActionPreference = 'Stop'
if (-not $RunOne) { throw 'Usar -RunOne para autorizar una sola tendencia V2.' }

$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$flag = Join-Path $root 'auto-editorial-v2.enabled'
$branchBase = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias'
$installerPath = Join-Path $env:TEMP 'Install-V2-Editorial-Auto.ps1'
$pilotPath = Join-Path $env:TEMP 'Run-V2-Editorial-One.ps1'

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'No se encontro la instalacion local de V2; no se modifica nada.'
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { throw 'Falta la tarea V2; no se supone una instalacion diferente.' }

Write-Host 'TT_V2_ONE_PILOT_PUBLICATION=NO'
Write-Host 'TT_V2_ONE_PILOT_V1_UNTOUCHED=YES'
Write-Host 'TT_V2_ONE_PILOT_WORKER_DEPLOY=NO'

# Disable future scheduled launches without stopping/killing a running chat.
Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
[IO.File]::WriteAllText($flag, "TT_V2_AUTO_EDITORIAL_ENABLED=NO`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'TT_V2_ONE_PILOT_AUTO_PAUSE_REQUESTED=YES'

# editorial_daemon_v2.py checks the flag after completing its current job.
# No force-kill, no Chrome profile deletion, and no second concurrent chat.
$profile = Join-Path $root 'ChromeProfile'
$paused = $false
for ($attempt = 0; $attempt -lt 360; $attempt++) {
    $active = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(python|pythonw|py|chrome)\.exe$' -and
        $_.CommandLine -and
        ($_.CommandLine -match 'editorial_(daemon|run)_v2\.py' -or
         ($_.CommandLine.Contains('--user-data-dir=') -and $_.CommandLine.Contains($profile)))
    })
    $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
    if ($active.Count -eq 0 -and $state -ne 'Running') {
        $paused = $true
        break
    }
    if ($attempt % 12 -eq 0) {
        Write-Host ('TT_V2_ONE_PILOT_WAITING_FOR_CURRENT_JOB=YES;processes=' + $active.Count)
    }
    Start-Sleep -Seconds 5
}
if (-not $paused) {
    throw 'El consumidor V2 no termino de forma natural. No instalar ni abrir otro Chrome.'
}
Write-Host 'TT_V2_ONE_PILOT_AUTO_PAUSED_AND_CHROME_CLOSED=YES'

# Refresh code and tests only after the current V2 job has exited.
Invoke-WebRequest -Uri ($branchBase + '/Install-V2-Editorial-Auto.ps1') -OutFile $installerPath -UseBasicParsing
& $installerPath -PilotOnly
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Instalacion piloto V2 no verificada.' }

# Run a single fresh, still-pending Top30 trend, with new explanation +
# one original ImageGen in the same ChatGPT conversation and exact GitHub ID.
Invoke-WebRequest -Uri ($branchBase + '/Run-V2-Editorial-One.ps1') -OutFile $pilotPath -UseBasicParsing
& $pilotPath -RunOne
Write-Host 'TT_V2_ONE_PILOT_FINISHED_CHECK_LOGS=YES'
Write-Host 'TT_V2_ONE_PILOT_AUTO_REMAINS_DISABLED=YES'
