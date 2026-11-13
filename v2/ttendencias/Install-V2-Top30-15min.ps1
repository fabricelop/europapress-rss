# TTActualidad V2: tarea aislada de Top30 cada 15 minutos.
# Se instala bajo el usuario actual; nunca modifica V1 ni publica.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$runner = Join-Path $root 'Run-V2-Top30-Tick.ps1'
$python = Join-Path $root 'top30_tick_v2.py'
$taskName = 'TTActualidadV2-Top30-15m'
if (!(Test-Path -LiteralPath $python)) { throw "Falta $python" }
if (!(Test-Path -LiteralPath $runner)) { throw "Falta $runner" }
if (!(Get-Command py.exe -ErrorAction SilentlyContinue)) { throw 'py.exe no disponible' }
if (!(Get-Command gh.exe -ErrorAction SilentlyContinue) -and -not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) { throw 'Se necesita gh auth o GH_TOKEN' }

# Cuartos de hora locales, 10 anos de duracion, sin solapamientos.
# No guardar credenciales: usar el login gh del usuario interactivo.
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
$now = Get-Date
$minutes = [Math]::Floor($now.TimeOfDay.TotalMinutes / 15) * 15 + 15
$next = $now.Date.AddMinutes($minutes)
$trigger = New-ScheduledTaskTrigger -Once -At $next -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
$task = Get-ScheduledTask -TaskName $taskName
if ($task.State -eq 'Disabled') { throw 'Tarea registrada pero desactivada' }
Write-Host 'TT_V2_TOP30_TASK_REGISTERED=YES'
Write-Host 'TT_V2_TOP30_INTERVAL_MINUTES=15'
Write-Host ('TT_V2_TOP30_NEXT_LOCAL=' + $next.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ('TT_V2_TOP30_TASK_NAME=' + $taskName)
Write-Host 'TT_V2_TOP30_TASK_MODE=WINDOWS_SESSION'
Write-Host 'TT_V2_PUBLISHED=NO'
