# TTActualidad V2: tarea aislada de Top30 cada 15 minutos.
# Se instala bajo el usuario actual; nunca modifica V1 ni publica.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$runner = Join-Path $root 'Run-V2-Top30-Tick.ps1'
$python = Join-Path $root 'top30_tick_v2.py'
$dependency = Join-Path $root 'persist_capture_github.py'
$taskName = 'TTActualidadV2-Top30-15m'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    throw 'Top30 V2 activo: esperar a que termine antes de actualizar su tarea'
}
# Una instalación previa podía no incluir el módulo del Top30 porque era opcional.
# Descargar SOLAMENTE los módulos que falten, sin pisar procesos V2 activos.
$source = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/'
New-Item -ItemType Directory -Path $root -Force | Out-Null
function Ensure-V2File([string]$filename, [string]$marker) {
    $destination = Join-Path $root $filename
    if (Test-Path -LiteralPath $destination) { return }
    $download = Join-Path $env:TEMP ('ttv2-top30-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Invoke-WebRequest -Uri ($source + $filename) -OutFile $download -UseBasicParsing
        if ((Get-Item -LiteralPath $download).Length -lt 400 -or
            !(Select-String -LiteralPath $download -Pattern $marker -SimpleMatch -Quiet)) {
            throw ('Módulo V2 no válido: ' + $filename)
        }
        Move-Item -LiteralPath $download -Destination $destination -ErrorAction Stop
        Write-Host ('TT_V2_TOP30_MODULE_INSTALLED=' + $filename)
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
Ensure-V2File 'top30_tick_v2.py' 'TT_V2_REFRESH_SLOT_UTC='
Ensure-V2File 'persist_capture_github.py' 'def token():'
Ensure-V2File 'Run-V2-Top30-Tick.ps1' 'TT_V2_TOP30_TICK_EXIT_CODE='
if (!(Get-Command py.exe -ErrorAction SilentlyContinue)) { throw 'py.exe no disponible' }
if (!(Get-Command gh.exe -ErrorAction SilentlyContinue) -and -not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) { throw 'Se necesita gh auth o GH_TOKEN' }

# Cuartos de hora locales, 10 anos de duracion, sin solapamientos.
# No guardar credenciales: usar el login gh del usuario interactivo.
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
$now = Get-Date
$minutes = [Math]::Floor($now.TimeOfDay.TotalMinutes / 15) * 15 + 15
$next = $now.Date.AddMinutes($minutes)
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $account),
    (New-ScheduledTaskTrigger -Once -At $next -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650))
)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
$task = Get-ScheduledTask -TaskName $taskName
if ($task.State -eq 'Disabled') { throw 'Tarea registrada pero desactivada' }
Write-Host 'TT_V2_TOP30_TASK_REGISTERED=YES'
Write-Host 'TT_V2_TOP30_INTERVAL_MINUTES=15'
Write-Host ('TT_V2_TOP30_NEXT_LOCAL=' + $next.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ('TT_V2_TOP30_TASK_NAME=' + $taskName)
Write-Host 'TT_V2_TOP30_TASK_MODE=WINDOWS_SESSION'
Write-Host 'TT_V2_TOP30_AT_LOGON=YES'
Write-Host 'TT_V2_PUBLISHED=NO'
