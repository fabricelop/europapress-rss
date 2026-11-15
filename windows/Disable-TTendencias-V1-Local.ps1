# Retirada reversible de la parte Windows de TTendencias V1.
# Por defecto SOLO informa. Se aplica con -Action Disable.
# No toca TTiTTulares, SeLoRecordamos, Chrome compartido ni TTActualidad V2.
param(
  [ValidateSet('Status','Disable','Restore')][string]$Action='Status',
  [ValidateRange(1,90)][int]$WaitMinutes=20
)
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$flag=Join-Path $base 'TTendencias-V1-Disabled.flag'
$backups=Join-Path $base 'TTendencias-V1-Retirement'
$startup=[Environment]::GetFolderPath('Startup')
$shortcut=Join-Path $startup 'TTendencias Mobile Trigger Listener.cmd'
$tasks=@('TTendencias Local','TTendencias Local Ready','TTendencias-XContext')
$listeners=@('TTendenciasDedicatedListener.ps1','TTendenciasMobileChatTriggerListener.ps1')
$guard=@('TT-LocalWatchdog.ps1','TT-AutoUpdater.ps1','TTendenciasDedicatedListener.ps1')
$marker='TTENDENCIAS_V1_RETIRE_GUARD'

function Say([string]$msg){Write-Host $msg}
function Processes {
  return @(Get-CimInstance Win32_Process -ErrorAction Stop)
}
function ExistingTasks {
  $rows=@()
  foreach($name in $tasks){
    $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if($task){$rows+=@{name=$name;state=[string]$task.State}}
  }
  return @($rows)
}
function BusyLegacy {
  $names='(?i)(TTendenciasImageBridge[.]js|TTendenciasWebImages[.]cjs|Run-TTendencias-X-Local[.]ps1|(?:Ejecutar[.]js|TT-Editorial-Guard[.]js).{0,180}\btendencias\b|LanzarOculto[.]vbs.{0,80}\btendencias\b)'
  $found=@(Processes|Where-Object{[string]$_.CommandLine -match $names})
  $running=@(ExistingTasks|Where-Object{$_.state -eq 'Running'})
  return @{processes=$found;tasks=$running}
}
function LegacyListeners {
  return @(Processes|Where-Object{
    ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
    (([string]$_.CommandLine -match '(?i)TTendenciasDedicatedListener[.]ps1') -or
     ([string]$_.CommandLine -match '(?i)TTendenciasMobileChatTriggerListener[.]ps1'))
  })
}
function RequirePreparedGuards {
  foreach($name in $guard){
    $path=Join-Path $base $name
    if(-not (Test-Path -LiteralPath $path)){
      throw ('Falta el programa compartido: '+$name+'. No se ha modificado nada.')
    }
    $content=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    if(-not $content.Contains($marker)){
      throw ('Proteccion pendiente en '+$name+'. Espera la actualizacion automatica y vuelve a intentarlo. Sin cambios.')
    }
  }
}
function State {
  Say ('TT_V1_WINDOWS_DISABLED='+$(if(Test-Path -LiteralPath $flag){'YES'}else{'NO'}))
  foreach($task in ExistingTasks){Say ('TT_V1_TASK '+$task.name+'='+$task.state)}
  Say ('TT_V1_STARTUP='+$(if(Test-Path -LiteralPath $shortcut){'YES'}else{'NO'}))
  Say ('TT_V1_LISTENERS='+(LegacyListeners).Count)
  $busy=BusyLegacy
  Say ('TT_V1_BUSY_PROCESSES='+@($busy.processes).Count)
  Say ('TT_V1_BUSY_TASKS='+@($busy.tasks).Count)
}
function Restore {
  if(-not (Test-Path -LiteralPath $flag)){Say 'TT_V1_WINDOWS_ALREADY_ENABLED=YES';return}
  $latest=Get-ChildItem -LiteralPath $backups -Directory -ErrorAction SilentlyContinue|
    Sort-Object Name -Descending|Select-Object -First 1
  if(-not $latest){throw 'Falta copia de seguridad; no se ha cambiado nada.'}
  $meta=Get-Content -LiteralPath (Join-Path $latest.FullName 'state.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Remove-Item -LiteralPath $flag -Force
  foreach($task in @($meta.tasks)){
    if($task.state -eq 'Disabled'){continue}
    $current=Get-ScheduledTask -TaskName ([string]$task.name) -ErrorAction SilentlyContinue
    if($current -and [string]$current.State -eq 'Disabled'){
      Enable-ScheduledTask -TaskName ([string]$task.name) -ErrorAction Stop|Out-Null
    }
  }
  $saved=Join-Path $latest.FullName 'startup.cmd'
  if((Test-Path -LiteralPath $saved) -and -not (Test-Path -LiteralPath $shortcut)){
    Copy-Item -LiteralPath $saved -Destination $shortcut -ErrorAction Stop
  }
  Say 'TT_V1_WINDOWS_RESTORED=YES (las tareas antiguas pueden reanudarse)'
}
if($Action -eq 'Status'){State;exit 0}
if($Action -eq 'Restore'){Restore;exit 0}

if(-not (Test-Path -LiteralPath $base -PathType Container)){throw 'Instalacion TT antigua no encontrada.'}
if(Test-Path -LiteralPath $flag){Say 'TT_V1_WINDOWS_ALREADY_DISABLED=YES';State;exit 0}
$v2=Get-ScheduledTask -TaskName 'TTActualidadV2-Editorial-Auto' -ErrorAction SilentlyContinue
if(-not $v2 -or [string]$v2.State -eq 'Disabled'){
  throw 'No se confirma V2 activa en Windows. Desactivacion cancelada.'
}
RequirePreparedGuards
Say 'TT_V1_RETIRE_CHECKING_ACTIVE_JOBS=YES'
$until=(Get-Date).AddMinutes($WaitMinutes)
do{
  $busy=BusyLegacy
  if(@($busy.processes).Count -eq 0 -and @($busy.tasks).Count -eq 0){break}
  if((Get-Date) -ge $until){
    Say 'TT_V1_RETIRE_DEFERRED=ACTIVE_WORK_IN_PROGRESS'
    throw 'Hay un trabajo antiguo activo. No se ha desactivado nada; vuelve a intentarlo despues.'
  }
  Start-Sleep -Seconds 5
}while($true)

New-Item -ItemType Directory -Path $backups -Force|Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$save=Join-Path $backups $stamp
New-Item -ItemType Directory -Path $save -ErrorAction Stop|Out-Null
$snapshot=@{tasks=@(ExistingTasks);created_at=(Get-Date).ToString('o');shortcut_present=(Test-Path -LiteralPath $shortcut)}
$utf8=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $save 'state.json'),($snapshot|ConvertTo-Json -Depth 5),$utf8)
if(Test-Path -LiteralPath $shortcut){
  Copy-Item -LiteralPath $shortcut -Destination (Join-Path $save 'startup.cmd') -ErrorAction Stop
}

# Revalidate immediately before the irreversible phase of process stopping.
$busy=BusyLegacy
if(@($busy.processes).Count -gt 0 -or @($busy.tasks).Count -gt 0){
  Say 'TT_V1_RETIRE_DEFERRED=NEW_WORK_STARTED'
  throw 'Aparecio un trabajo nuevo; no se ha modificado nada.'
}
[IO.File]::WriteAllText($flag,('TTENDENCIAS_V1_DISABLED=YES '+(Get-Date).ToString('o')),$utf8)
foreach($task in ExistingTasks){
  if($task.state -ne 'Disabled'){
    Disable-ScheduledTask -TaskName $task.name -ErrorAction Stop|Out-Null
  }
}
if(Test-Path -LiteralPath $shortcut){
  Move-Item -LiteralPath $shortcut -Destination (Join-Path $save 'startup.disabled.cmd') -ErrorAction Stop
}
foreach($p in LegacyListeners){
  Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
}
Start-Sleep -Seconds 7
if((LegacyListeners).Count -gt 0){throw 'El receptor antiguo sigue abierto: comprobar vigilancia compartida.'}
foreach($task in ExistingTasks){
  if($task.state -ne 'Disabled'){throw ('La tarea sigue activa: '+$task.name)}
}
Say 'TT_V1_WINDOWS_DISABLED=YES'
Say 'TT_V1_BACKUP_READY=YES'
Say 'TT_V2_PRESERVED=YES'
Say 'TTITTULARES_PRESERVED=YES'
Say 'TT_V1_NEXT_CHECK=esperar 2 minutos; repetir con -Action Status'
