# Surgical local watchdog patch: preserve shared Chrome 9223 and SeLoRecordamos.
[CmdletBinding()]
param([string]$BaseDir='C:\TTiTTulares',[switch]$RestartWatchdog)
$ErrorActionPreference='Stop'

function Add-TTV1WatchdogRetirement([string]$Source){
  $tokens=$null;$parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count){throw 'Watchdog original no supera analisis sintactico; no se modifica.'}
  $functions=@{}
  foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($functions.ContainsKey($function.Name)){throw ('Funcion duplicada; no se modifica: '+$function.Name)}
    $functions[$function.Name]=$function
  }
  $contracts=@{
    StartHiddenPs=@('Script','Tag');EnsureSingle=@('Pattern','Script','Tag');EnsureStartup=@('Name','Script');
    EnsureScheduledTasks=@();'Recover-ListenersAfterReconnect'=@();EnsureEditorialScheduledWake=@();
    EnsureTTitRequestedImageRecovery=@();EnsureRemoteTelegramHeal=@();TrendsV1Enabled=@();EnsureChrome=@()
  }
  foreach($name in $contracts.Keys){
    if(-not $functions.ContainsKey($name)){throw ('Funcion esperada ausente: '+$name)}
    $actual=@($functions[$name].Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})
    if(($actual -join '|') -cne ($contracts[$name] -join '|')){throw ('Firma local desconocida: '+$name)}
  }
  $markers=@('TT_V1_RETIRE_START','TT_V1_RETIRE_SINGLE','TT_V1_RETIRE_STARTUP',
    'TT_V1_RETIRE_TASK','TT_V1_RETIRE_RECONNECT','TT_V1_RETIRE_WAKE','TT_V1_RETIRE_IMAGE','TT_V1_RETIRE_REMOTE_HEAL')
  if($Source.Contains('# TT_V1_WATCHDOG_RETIRE_GUARD_V1')){
    foreach($marker in $markers){if(-not $Source.Contains('# '+$marker)){throw 'Parche parcial o desconocido; no se modifica.'}}
    foreach($name in @('Test-TTV1ProjectRetired','Test-TTV1ScriptRetired','Test-TTV1TaskRetired')){
      if(-not $functions.ContainsKey($name)){throw 'Parche parcial sin helpers; no se modifica.'}
    }
    return [pscustomobject]@{source=$Source;changed=$false}
  }
  foreach($name in @('Test-TTV1ProjectRetired','Test-TTV1ScriptRetired','Test-TTV1TaskRetired')){
    if($functions.ContainsKey($name)){throw 'Helper local previo desconocido; no se modifica.'}
  }
  $helpers=@'

# TT_V1_WATCHDOG_RETIRE_GUARD_V1
function Test-TTV1ProjectRetired([string]$Project){
  switch($Project){
    'ttittulares' {return (Test-Path -LiteralPath (Join-Path $BaseDir 'TTiTTulares-V1-Disabled.flag'))}
    'ttendencias' {return (Test-Path -LiteralPath (Join-Path $BaseDir 'TTendencias-V1-Disabled.flag'))}
    default {return $false}
  }
}
function Test-TTV1ScriptRetired([string]$Script){
  $name=[IO.Path]::GetFileName($Script)
  if($name -in @('TTiTTularesDedicatedListener.ps1','TTiTTularesMobileChatTriggerListener.ps1','TTiTTularesImageBridge.js')){
    return (Test-TTV1ProjectRetired 'ttittulares')
  }
  if($name -in @('TTendenciasDedicatedListener.ps1','TTendenciasMobileChatTriggerListener.ps1','TTendenciasImageBridge.js')){
    return (Test-TTV1ProjectRetired 'ttendencias')
  }
  if($name -in @('TT-AutoUpdater.ps1','MobileChatTriggerListener.ps1')){
    return ((Test-TTV1ProjectRetired 'ttittulares') -and (Test-TTV1ProjectRetired 'ttendencias'))
  }
  return $false
}
function Test-TTV1TaskRetired([string]$Name){
  if($Name -in @('TTiTTulares Local','TTiTTulares Local Ready','TTiTTulares-XContext')){
    return (Test-TTV1ProjectRetired 'ttittulares')
  }
  if($Name -in @('TTendencias Local','TTendencias Local Ready','TTendencias-XContext')){
    return (Test-TTV1ProjectRetired 'ttendencias')
  }
  return $false
}
'@
  $insertions=New-Object Collections.Generic.List[object]
  $insertions.Add([pscustomobject]@{offset=$functions['TrendsV1Enabled'].Extent.EndOffset;text=("`n"+$helpers+"`n")})
  $entryGuards=@{
    StartHiddenPs="`n  # TT_V1_RETIRE_START`n  if(Test-TTV1ScriptRetired `$Script){return `$null}`n";
    EnsureSingle="`n  # TT_V1_RETIRE_SINGLE`n  if(Test-TTV1ScriptRetired `$Script){return}`n";
    EnsureStartup="`n  # TT_V1_RETIRE_STARTUP`n  if(Test-TTV1ScriptRetired `$Script){return}`n";
    EnsureTTitRequestedImageRecovery="`n  # TT_V1_RETIRE_IMAGE`n  if(Test-TTV1ProjectRetired 'ttittulares'){return}`n";
    EnsureRemoteTelegramHeal="`n  # TT_V1_RETIRE_REMOTE_HEAL`n  if((Test-TTV1ProjectRetired 'ttittulares') -and (Test-TTV1ProjectRetired 'ttendencias')){return}`n"
  }
  foreach($name in $entryGuards.Keys){
    $insertions.Add([pscustomobject]@{offset=($functions[$name].Body.Extent.StartOffset+1);text=$entryGuards[$name]})
  }
  foreach($spec in @(
    @{'function'='EnsureScheduledTasks';variable='name';marker='TT_V1_RETIRE_TASK';condition='Test-TTV1TaskRetired $name'},
    @{'function'='Recover-ListenersAfterReconnect';variable='target';marker='TT_V1_RETIRE_RECONNECT';condition='Test-TTV1ScriptRetired $target.Name'},
    @{'function'='EnsureEditorialScheduledWake';variable='spec';marker='TT_V1_RETIRE_WAKE';condition="Test-TTV1ProjectRetired `$spec.project"}
  )){
    $variable=[string]$spec.variable
    $loops=@($functions[$spec.function].Body.FindAll({param($node)
      $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -ceq $variable
    },$true))
    if($loops.Count -ne 1){throw ('Bucle local desconocido o ambiguo: '+$spec.function)}
    $insertions.Add([pscustomobject]@{offset=($loops[0].Body.Extent.StartOffset+1);
      text=("`n    # "+$spec.marker+"`n    if("+$spec.condition+"){continue}`n")})
  }
  $fixed=$Source
  foreach($insertion in @($insertions | Sort-Object offset -Descending)){$fixed=$fixed.Insert($insertion.offset,$insertion.text)}
  $newAst=[Management.Automation.Language.Parser]::ParseInput($fixed,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count){throw 'Parche no supera analisis sintactico; no se modifica.'}
  $chrome=@($newAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'EnsureChrome'},$true))
  if($chrome.Count -ne 1 -or $chrome[0].Extent.Text -cne $functions['EnsureChrome'].Extent.Text){throw 'EnsureChrome no debe cambiar.'}
  return [pscustomobject]@{source=$fixed;changed=$true}
}

function Test-TTExactWatchdogProcess($Process,[string]$Path){
  if(-not $Process -or $Process.Name -notin @('powershell.exe','pwsh.exe')){return $false}
  if([int]$Process.ProcessId -eq $PID){return $false}
  $pattern='(?i)(?:^|\s)-File\s+(?:"'+[regex]::Escape($Path)+'"|'+[regex]::Escape($Path)+'(?=\s|$))'
  return ([string]$Process.CommandLine -match $pattern)
}

$watchdog=Join-Path $BaseDir 'TT-LocalWatchdog.ps1'
if(-not (Test-Path -LiteralPath $watchdog -PathType Leaf)){throw "No existe $watchdog"}
if($RestartWatchdog -and -not (Test-Path -LiteralPath (Join-Path $BaseDir 'TTiTTulares-V1-Disabled.flag')) -and
   -not (Test-Path -LiteralPath (Join-Path $BaseDir 'TTendencias-V1-Disabled.flag'))){
  throw 'No hay flags de retirada V1; no se reinicia el supervisor.'
}
$originalHash=(Get-FileHash -LiteralPath $watchdog -Algorithm SHA256).Hash
$original=[IO.File]::ReadAllText($watchdog)
$patch=Add-TTV1WatchdogRetirement $original
$backup=$null
if($patch.changed){
  $backup=Join-Path $BaseDir ('Backup-Watchdog-V1-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
  New-Item -ItemType Directory -Path $backup | Out-Null
  $saved=Join-Path $backup 'TT-LocalWatchdog.ps1'
  Copy-Item -LiteralPath $watchdog -Destination $saved
  $expected=$originalHash
  if((Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -ne $expected){throw 'Watchdog cambio antes de guardar la copia; no se sobrescribe.'}
  $temporary=Join-Path $BaseDir ('TT-LocalWatchdog.retire-'+[Guid]::NewGuid().ToString('N')+'.ps1')
  try{
    [IO.File]::WriteAllText($temporary,$patch.source,(New-Object Text.UTF8Encoding($false)))
    if((Get-FileHash -LiteralPath $watchdog -Algorithm SHA256).Hash -ne $expected){throw 'Watchdog cambio concurrentemente; no se sobrescribe.'}
    Move-Item -LiteralPath $temporary -Destination $watchdog -Force
  }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
  Write-Host ('COPIA_SEGURIDAD='+$backup)
  Write-Host 'WATCHDOG_V1=GUARDIAS_INSTALADAS'
}else{Write-Host 'WATCHDOG_V1=GUARDIAS_YA_INSTALADAS'}

# Only the shared supervisor itself is refreshed. Its children, Chrome and
# SeLoRecordamos are never stopped. No task or Chrome launcher is disabled.
$stopped=@();$started=$null
if($RestartWatchdog){
  if(-not $backup){
    $backup=Join-Path $BaseDir ('Backup-Watchdog-V1-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    Copy-Item -LiteralPath $watchdog -Destination (Join-Path $backup 'TT-LocalWatchdog.ps1')
  }
  $candidates=@(Get-CimInstance Win32_Process | Where-Object {Test-TTExactWatchdogProcess $_ $watchdog})
  foreach($candidate in $candidates){
    $fresh=Get-CimInstance Win32_Process -Filter ('ProcessId='+$candidate.ProcessId)
    if((Test-TTExactWatchdogProcess $fresh $watchdog) -and $fresh.CreationDate -eq $candidate.CreationDate){
      Stop-Process -Id $fresh.ProcessId -Force
      $stopped+=([int]$fresh.ProcessId)
    }
  }
  Start-Sleep -Seconds 2
  $live=@(Get-CimInstance Win32_Process | Where-Object {Test-TTExactWatchdogProcess $_ $watchdog})
  if($live.Count -eq 0){
    $started=Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$watchdog+'"')) -WindowStyle Hidden -PassThru
  }
  Start-Sleep -Seconds 2
  $live=@(Get-CimInstance Win32_Process | Where-Object {Test-TTExactWatchdogProcess $_ $watchdog})
  if($live.Count -ne 1){throw ('Supervisor vivo no confirmado de forma unica: '+$live.Count+'; no se toca Chrome ni SeLoRecordamos.')}
  Write-Host ('WATCHDOG_RECARGADO_PID='+$live[0].ProcessId)
}else{Write-Host 'WATCHDOG_RECARGA=PENDIENTE_USAR_RESTARTWATCHDOG_PARA_APLICAR_AL_PROCESO_ACTIVO'}

# Persist the original V1 task retirement after the old watchdog is gone.
# Never disable Chrome tasks or any SeLoRecordamos/V2 task.
$disabled=@()
if($RestartWatchdog){
  foreach($spec in @(@{flag='TTiTTulares-V1-Disabled.flag';names=@('TTiTTulares Local','TTiTTulares Local Ready','TTiTTulares-XContext')},
                    @{flag='TTendencias-V1-Disabled.flag';names=@('TTendencias Local','TTendencias Local Ready','TTendencias-XContext')})){
    if(-not (Test-Path -LiteralPath (Join-Path $BaseDir $spec.flag))){continue}
    foreach($name in $spec.names){
      $task=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
      if($task -and [string]$task.State -ne 'Disabled'){
        if($backup){Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Set-Content -LiteralPath (Join-Path $backup ('task-'+$task.TaskName+'.xml')) -Encoding UTF8}
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
        Write-Host ('TAREA_V1_DESACTIVADA='+$task.TaskName)
        $disabled+=([string]$task.TaskName)
      }
    }
  }
}
$report=[ordered]@{at=(Get-Date).ToString('o');watchdog=$watchdog;backup=$backup;source_changed=$patch.changed;
  restart_requested=[bool]$RestartWatchdog;supervisor_pids_stopped=$stopped;
  supervisor_pid_started=$(if($started){$started.Id}else{$null});v1_tasks_disabled=$disabled;
  chrome_stopped=$false;chrome_task_disabled=$false;selorecordamos_stopped=$false;
  note='Chrome 9223 compartido permanece activo. Solo se impide al supervisor relanzar/reautorizar los ejecutores V1 retirados.'}
if($backup){$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'result.json') -Encoding UTF8}
Write-Host 'WATCHDOG_V1_RETIRADA=APLICADA_EN_ARCHIVO_CHROME_Y_SELORECORDAMOS_CONSERVADOS'
