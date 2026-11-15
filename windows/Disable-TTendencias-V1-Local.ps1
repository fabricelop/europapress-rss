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
# El receptor movil es opcional en instalaciones historicas.
if(Test-Path -LiteralPath (Join-Path $base 'TTendenciasMobileChatTriggerListener.ps1')){
  $guard+='TTendenciasMobileChatTriggerListener.ps1'
}
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
function DisableLegacyScheduledTasks {
  foreach($task in ExistingTasks){
    if($task.state -ne 'Disabled'){
      Disable-ScheduledTask -TaskName $task.name -ErrorAction Stop|Out-Null
    }
  }
}
function StopLegacyListeners {
  foreach($p in LegacyListeners){
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
function RestartSharedSupervisors {
  # Los procesos cargados en memoria pueden seguir ejecutando la version vieja
  # aunque el archivo actualizado ya contenga la proteccion de V1.
  $targets=@(Processes|Where-Object{
    ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
    (([string]$_.CommandLine -match '(?i)TT-LocalWatchdog[.]ps1') -or
     ([string]$_.CommandLine -match '(?i)TT-AutoUpdater[.]ps1'))
  })
  foreach($p in $targets){
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 700
  $watchdog=Join-Path $base 'TT-LocalWatchdog.ps1'
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$watchdog) -WindowStyle Hidden -WorkingDirectory $base -PassThru -ErrorAction Stop
  Start-Sleep -Seconds 7
  $p.Refresh()
  if($p.HasExited){throw 'No se pudo iniciar la vigilancia compartida. V1 permanece marcada como retirada.'}
  Say 'TT_V1_SHARED_SUPERVISORS_RELOADED=YES'
}
function State {
  $stateTasks=@(ExistingTasks)
  $startupPresent=Test-Path -LiteralPath $shortcut
  $listenerCount=(LegacyListeners).Count
  $busy=BusyLegacy
  $retired=Test-Path -LiteralPath $flag
  $allTasksOff=@($stateTasks|Where-Object{$_.state -ne 'Disabled'}).Count -eq 0
  $fullyOff=$retired -and $allTasksOff -and -not $startupPresent -and $listenerCount -eq 0 -and @($busy.processes).Count -eq 0 -and @($busy.tasks).Count -eq 0
  $result=if($fullyOff){'YES'}elseif($retired){'PARTIAL'}else{'NO'}
  Say ('TT_V1_WINDOWS_DISABLED='+$result)
  foreach($task in $stateTasks){Say ('TT_V1_TASK '+$task.name+'='+$task.state)}
  Say ('TT_V1_STARTUP='+$(if($startupPresent){'YES'}else{'NO'}))
  Say ('TT_V1_LISTENERS='+$listenerCount)
  Say ('TT_V1_BUSY_PROCESSES='+@($busy.processes).Count)
  Say ('TT_V1_BUSY_TASKS='+@($busy.tasks).Count)
}
function WaitForQuiet {
  # Primero se cierran las entradas nuevas, despues se espera a los trabajos en curso.
  Say 'TT_V1_RETIRE_WAITING_FOR_EXISTING_JOBS=YES'
  $until=(Get-Date).AddMinutes($WaitMinutes)
  $quietChecks=0
  do{
    $busy=BusyLegacy
    $live=(LegacyListeners).Count
    if(@($busy.processes).Count -eq 0 -and @($busy.tasks).Count -eq 0 -and $live -eq 0){
      $quietChecks++
      if($quietChecks -ge 3){return}
    }else{
      $quietChecks=0
    }
    if((Get-Date) -ge $until){
      Say 'TT_V1_RETIRE_DRAINING=YES'
      throw 'V1 ya no acepta trabajos nuevos, pero alguno anterior sigue terminando. La retirada queda activada y se puede comprobar mas tarde.'
    }
    Start-Sleep -Seconds 5
  }while($true)
}
function AssertDisabled {
  if(-not (Test-Path -LiteralPath $flag)){throw 'Falta marca de retirada de V1.'}
  foreach($task in ExistingTasks){
    if($task.state -ne 'Disabled'){throw ('La tarea antigua sigue habilitada: '+$task.name)}
  }
  if(Test-Path -LiteralPath $shortcut){throw 'El arranque automatico antiguo sigue presente.'}
  if((LegacyListeners).Count -gt 0){throw 'Un receptor antiguo sigue abierto.'}
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
if(Test-Path -LiteralPath $flag){
  RequirePreparedGuards
  $needsRepair=@(ExistingTasks|Where-Object{$_.state -ne 'Disabled'}).Count -gt 0
  if($needsRepair -or (LegacyListeners).Count -gt 0 -or (Test-Path -LiteralPath $shortcut)){
    Say 'TT_V1_RETIRE_REPAIRING_REACTIVATION=YES'
    StopLegacyListeners
    DisableLegacyScheduledTasks
    if(Test-Path -LiteralPath $shortcut){
      $last=Get-ChildItem -LiteralPath $backups -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending|Select-Object -First 1
      if(-not $last){throw 'Falta copia de seguridad para retirar el arranque antiguo.'}
      Move-Item -LiteralPath $shortcut -Destination (Join-Path $last.FullName 'startup.repaired.cmd') -Force -ErrorAction Stop
    }
    RestartSharedSupervisors
    DisableLegacyScheduledTasks
  }
  WaitForQuiet
  Start-Sleep -Seconds 70
  AssertDisabled
  Say 'TT_V1_WINDOWS_ALREADY_DISABLED=YES'
  State
  exit 0
}
$v2=Get-ScheduledTask -TaskName 'TTActualidadV2-Editorial-Auto' -ErrorAction SilentlyContinue
if(-not $v2 -or [string]$v2.State -eq 'Disabled'){
  throw 'No se confirma V2 activa en Windows. Desactivacion cancelada.'
}
RequirePreparedGuards
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

# Bloquear nuevas entradas antes de esperar al trabajo que ya estaba en marcha.
[IO.File]::WriteAllText($flag,('TTENDENCIAS_V1_DISABLED=YES '+(Get-Date).ToString('o')),$utf8)
DisableLegacyScheduledTasks
if(Test-Path -LiteralPath $shortcut){
  Move-Item -LiteralPath $shortcut -Destination (Join-Path $save 'startup.disabled.cmd') -ErrorAction Stop
}
StopLegacyListeners
RestartSharedSupervisors
DisableLegacyScheduledTasks
Say 'TT_V1_RETIRE_NO_NEW_WORK=YES'
WaitForQuiet
Start-Sleep -Seconds 70
AssertDisabled
Say 'TT_V1_WINDOWS_DISABLED=YES'
Say 'TT_V1_BACKUP_READY=YES'
Say 'TT_V2_PRESERVED=YES'
Say 'TTITTULARES_PRESERVED=YES'
Say 'TT_V1_NEXT_CHECK=esperar 2 minutos; repetir con -Action Status'
