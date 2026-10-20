#requires -Version 5.1
<#
TT Chrome 9223 controlled emergency recovery v1.
ONLY the dedicated ChromeAuto browser on 9223 is restarted.
9234 TTImageRelay, normal Chrome, cookies, GitHub queues and TTActualidad web
remain untouched. Session tab files are preserved in an external backup.
The TT watchdog/listeners and TT editorial scheduled triggers are paused and
restored around the restart to prevent concurrent Chrome launches.
#>
[CmdletBinding()]
param([switch]$InspectOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
# Fail before ANY changes unless the shell is elevated. Standard Windows task
# ACLs reject disabling the TT scheduled tasks without Administrator rights.
$isAdmin=([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
  Write-Host 'TT9223 PERMISOS: ejecuta PowerShell como administrador y vuelve a lanzar el script. NO se ha modificado nada.' -ForegroundColor Yellow
  exit 5
}
$base='C:\TTiTTulares'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$dir=Join-Path $env:LOCALAPPDATA ('TT_Recuperacion\Chrome9223-'+$stamp)
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$log=Join-Path $dir 'recovery.log'
function Note([string]$message) {
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' TT9223 '+$message
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
function FindRoots {
  return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
    Where-Object {
      [string]$_.CommandLine -match '(?i)--remote-debugging-port(?:=|\s+)9223(?:\s|$)' -and
      [string]$_.CommandLine -notmatch '(?i)(?:^|\s)--type='
    })
}
function FindPort9234 {
  return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      [string]$_.CommandLine -match '(?i)--remote-debugging-port(?:=|\s+)9234(?:\s|$)' -and
      [string]$_.CommandLine -notmatch '(?i)(?:^|\s)--type='
    })
}
function PortReady {
  try {
    $version=Invoke-RestMethod -Uri 'http://127.0.0.1:9223/json/version' -TimeoutSec 4 -ErrorAction Stop
    return [bool]([string]$version.webSocketDebuggerUrl)
  } catch { return $false }
}
function Memory {
  try {
    $m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    Note ('COMMIT used_GB='+[math]::Round([double]$m.CommittedBytes/1GB,2)+
      ' limit_GB='+[math]::Round([double]$m.CommitLimit/1GB,2))
  }catch{ Note ('COMMIT unavailable: '+$_.Exception.Message) }
}
function GetCommandArg([string]$command,[string]$name) {
  $match=[regex]::Match($command,'(?i)--'+[regex]::Escape($name)+'=(?:"(?<quoted>[^"]+)"|(?<bare>\S+))')
  if(-not $match.Success){return ''}
  if($match.Groups['quoted'].Success){return [string]$match.Groups['quoted'].Value}
  return [string]$match.Groups['bare'].Value
}
function PageCounts {
  $response=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9223/json/list' -TimeoutSec 8 -ErrorAction Stop
  $targets=@(ConvertFrom-Json -InputObject ([string]$response.Content))
  $pages=@($targets|Where-Object{[string]$_.type -eq 'page'})
  $homes=@($pages|Where-Object{[string]$_.url -eq 'https://chatgpt.com/'})
  $conversations=@($pages|Where-Object{[string]$_.url -match '^https://chatgpt[.]com/c/'})
  Note ('CDP pages='+$pages.Count+' home='+$homes.Count+' conversations='+$conversations.Count)
  return $pages.Count
}
function SuspendNamed([string]$name) {
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if(-not $task){return}
  if([string]$task.State -eq 'Disabled'){return}
  Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
  # Track it only AFTER successful suspension (not before HRESULT 0x80070005).
  $script:pausedTasks.Add($name)
  # Never stop the Chrome launcher task while its browser is still alive:
  # Task Scheduler could kill Chrome before session protection is ready.
  if($name -ne 'TT Chrome Auto') {
    try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue }catch{}
  }
  Note ('TASK PAUSED '+$name)
}
function RestoreTasks {
  foreach($name in $script:pausedTasks) {
    try {
      Enable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
      Note ('TASK RESTORED '+$name)
    }catch{ Note ('TASK RESTORE FAILED '+$name+' '+$_.Exception.Message) }
  }
  $script:pausedTasks.Clear()
}
function FindManagers {
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -in @('powershell.exe','pwsh.exe') -and
      [string]$_.CommandLine -match '(?i)(?:^|\s)-File\s+"?C:\\TTiTTulares\\(?:TT-LocalWatchdog|TTiTTularesDedicatedListener|TTendenciasDedicatedListener)[.]ps1(?:["\s]|$)' -and
      [int]$_.ProcessId -ne $PID
    })
}
function FindRunners {
  return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      [string]$_.CommandLine -match '(?i)(?:TTiTTulares|TTendencias)ImageBridge[.]js|[\\/]Ejecutar[.]js|[\\/]TT-Editorial-Tab-Watch[.]js'
    })
}
function RestartManager([string]$scriptName) {
  $file=Join-Path $base $scriptName
  if(-not(Test-Path -LiteralPath $file)) { Note ('MANAGER MISSING '+$file);return }
  $live=@(FindManagers|Where-Object{[string]$_.CommandLine -like ('*'+$scriptName+'*')})
  if($live.Count -gt 0){ Note ('MANAGER ALREADY RUNNING '+$scriptName);return }
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$file+'"')
  ) -WorkingDirectory $base -WindowStyle Hidden -PassThru -ErrorAction Stop
  Note ('MANAGER RESTARTED '+$scriptName+' pid='+$p.Id)
}
$script:pausedTasks=New-Object 'System.Collections.Generic.List[string]'
$script:previousManagers=New-Object 'System.Collections.Generic.List[string]'
$script:chromeWasStopped=$false
$script:chromeRestarted=$false
$mutex=New-Object System.Threading.Mutex($false,'Local\TTChrome9223ControlledRecovery')
$locked=$false
try {
  try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
  if(-not $locked){throw 'Otra recuperación Chrome9223 ya está ejecutándose'}
  Note 'BEGIN controlled Chrome9223 recovery'
  Memory
  $rootTask=Get-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
  if([string]$rootTask.State -eq 'Disabled'){throw 'TT Chrome Auto ya está deshabilitada; no modificar su configuración'}
  # Check task editing rights while everything is still running by reading its
  # security descriptor. The real Disable is done only after full preflight.
  $taskAction=([string](($rootTask.Actions | Select-Object -First 1).Execute))
  Note ('CHROME_TASK execute='+$taskAction)
  if(@($rootTask.Actions).Count -lt 1){throw 'TT Chrome Auto no tiene acción configurada'}
  $roots=@(FindRoots)
  if($roots.Count -ne 1){throw ('Se esperaba 1 Chrome root en 9223; encontrados='+$roots.Count+'; sin cambios')}
  $root=$roots[0]
  $chromePid=[int]$root.ProcessId
  $profile=GetCommandArg ([string]$root.CommandLine) 'user-data-dir'
  if([string]::IsNullOrWhiteSpace($profile)){throw 'No se reconoce perfil --user-data-dir en 9223; sin cambios'}
  $profile=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($profile))
  $baseFull=[IO.Path]::GetFullPath($base).TrimEnd('\')+'\'
  $isolated=($profile.IndexOf($baseFull,[StringComparison]::OrdinalIgnoreCase) -eq 0) -or
            ($profile -match '(?i)(?:^|[\\/])ChromeAuto(?:[\\/]|$)')
  if(-not $isolated){throw ('Perfil 9223 no reconocido como dedicado: '+$profile+'; sin cambios')}
  if(-not(Test-Path -LiteralPath $profile)){throw 'Perfil ChromeAuto no encontrado; sin cambios'}
  $profileName=GetCommandArg ([string]$root.CommandLine) 'profile-directory'
  if(-not $profileName){$profileName='Default'}
  if($profileName -match '[\\/]|\.\.'){throw 'Nombre de perfil Chrome inesperado; sin cambios'}
  $userProfileDir=Join-Path $profile $profileName
  if(-not(Test-Path -LiteralPath $userProfileDir)){throw ('No existe '+$userProfileDir+'; sin cambios')}
  $ttImageBefore=@(FindPort9234|ForEach-Object{$_.ProcessId})
  Note ('IDENTIFIED chrome9223_pid='+$chromePid+' isolated_profile='+$profile+' chrome9234_pids='+($ttImageBefore -join ','))
  [IO.File]::WriteAllText((Join-Path $dir 'chrome9223-root-command.txt'),[string]$root.CommandLine,[Text.Encoding]::UTF8)
  try {[void](PageCounts)}catch{Note ('CDP PRE unavailable: '+$_.Exception.Message)}
  if($InspectOnly){Note 'INSPECT ONLY; no changes';return}
  # Install the conservative cleanup for the normal TT watchdog BEFORE pausing it.
  $pruneUrl='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/TT-Chrome9223-Safe-Prune.js'
  $tmp=Join-Path $dir 'TT-Chrome9223-Safe-Prune.new.js'
  Invoke-WebRequest -UseBasicParsing -Uri $pruneUrl -OutFile $tmp -TimeoutSec 25 -ErrorAction Stop
  $node=(Get-Command node.exe -ErrorAction Stop).Source
  $pruneText=[IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
  if(-not $pruneText.Contains('const MIN_KEEP_HOME=3;') -or
     -not $pruneText.Contains('const MAX_SCAN=250;') -or
     -not $pruneText.Contains('checkBusy()')){
    throw 'Versión de limpiador inesperada; no se ha tocado Chrome'
  }
  & $node --check $tmp | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Limpiador JS inválido; sin cambios'}
  foreach($mgr in @(FindManagers)){
    $cmd=[string]$mgr.CommandLine
    foreach($name in @('TTiTTularesDedicatedListener.ps1','TTendenciasDedicatedListener.ps1','TT-LocalWatchdog.ps1')){
      if($cmd -match [regex]::Escape($name) -and -not $script:previousManagers.Contains($name)){
        $script:previousManagers.Add($name)
      }
    }
  }
  # Turn off scheduled triggers first; stop watchdog to prevent auto-relaunch.
  foreach($name in @('TTiTTulares Local Ready','TTendencias Local Ready','TTiTTulares Local','TTendencias Local','TT Chrome Auto')){
    SuspendNamed $name
  }
  foreach($mgr in @(FindManagers)){
    try {
      Stop-Process -Id ([int]$mgr.ProcessId) -Force -ErrorAction Stop
      Note ('MANAGER PAUSED pid='+$mgr.ProcessId)
    }catch{Note ('MANAGER STOP FAILED pid='+$mgr.ProcessId+' '+$_.Exception.Message)}
  }
  Start-Sleep -Seconds 2
  $managersStill=@(FindManagers)
  if($managersStill.Count -gt 0){throw ('TT managers remain active='+$managersStill.Count+'; Chrome not stopped')}
  foreach($runner in @(FindRunners)){
    try {
      Stop-Process -Id ([int]$runner.ProcessId) -Force -ErrorAction Stop
      Note ('TT RUNNER PAUSED pid='+$runner.ProcessId)
    }catch{Note ('TT RUNNER STOP FAILED pid='+$runner.ProcessId+' '+$_.Exception.Message)}
  }
  $current=@(FindRoots)
  if($current.Count -ne 1 -or [int]$current[0].ProcessId -ne $chromePid){
    throw 'Chrome9223 root cambió durante la preparación; abortado para no cerrar navegador equivocado'
  }
  # Controlled termination affects exactly this browser family, never Chrome9234.
  Note ('STOPPING CHROME9223 root_pid='+$chromePid+' and its descendant processes')
  $oldPreference=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    $killResult=@(& "$env:WINDIR\System32\taskkill.exe" /PID $chromePid /T /F 2>&1)
    $killExit=$LASTEXITCODE
  } finally { $ErrorActionPreference=$oldPreference }
  Note ('TASKKILL exit='+$killExit+' messages='+@($killResult).Count)
  for($i=0;$i -lt 15;$i++){
    if(@(FindRoots).Count -eq 0){break}
    Start-Sleep -Seconds 1
  }
  if(@(FindRoots).Count -ne 0){throw 'Chrome9223 sigue vivo; no mover sesión'}
  $script:chromeWasStopped=$true
  # Back up only tab/session-restore metadata; cookies/login/profile settings stay.
  $sessionBackup=Join-Path $dir 'session-backup'
  New-Item -ItemType Directory -Path $sessionBackup -Force | Out-Null
  foreach($name in @('Sessions','Current Session','Last Session','Current Tabs','Last Tabs')){
    $source=Join-Path $userProfileDir $name
    if(Test-Path -LiteralPath $source){
      Move-Item -LiteralPath $source -Destination (Join-Path $sessionBackup $name) -ErrorAction Stop
      Note ('SESSION BACKED UP '+$name)
    }
  }
  # Install the cleanup helper for the normal watchdog's future sweeps.
  $target=Join-Path $base 'TT-Chrome9223-Safe-Prune.js'
  if(Test-Path -LiteralPath $target){
    Copy-Item -LiteralPath $target -Destination (Join-Path $dir 'TT-Chrome9223-Safe-Prune.before.js') -ErrorAction Stop
  }
  $staging=$target+'.memory-recovery.tmp.js'
  Copy-Item -LiteralPath $tmp -Destination $staging -Force -ErrorAction Stop
  Move-Item -LiteralPath $staging -Destination $target -Force -ErrorAction Stop
  Note 'FUTURE CLEANUP INSTALLED (empty unused 9223 home tabs only)'
  # Re-enable ONLY the browser launcher; leave editorial triggers paused.
  Enable-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop | Out-Null
  $null=$script:pausedTasks.Remove('TT Chrome Auto')
  try {Stop-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction SilentlyContinue}catch{}
  Start-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
  $ready=$false
  for($wait=0;$wait -lt 40;$wait++){
    Start-Sleep -Seconds 2
    if(PortReady){$ready=$true;break}
  }
  if(-not $ready){throw 'Chrome9223 no respondió tras reiniciar; watchdog/listeners se restaurarán'}
  $newRoots=@(FindRoots)
  if($newRoots.Count -ne 1){throw ('Chrome9223 reiniciado con root ambiguo='+$newRoots.Count)}
  $script:chromeRestarted=$true
  Note ('CHROME9223 RESTARTED new_pid='+[int]$newRoots[0].ProcessId)
  try {
    $count=PageCounts
    if($count -gt 35){Note ('WARNING restored_pages='+$count+' (revisar configuración TT Chrome Auto; sesión antigua respaldada)')}
  }catch{Note ('CDP POST unavailable '+$_.Exception.Message)}
  Memory
  $after=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue)
  Note ('CHROME AFTER total_processes='+$after.Count)
  $ttImageAfter=@(FindPort9234|ForEach-Object{$_.ProcessId})
  Note ('TTIMAGES 9234 before='+($ttImageBefore -join ',')+' after='+($ttImageAfter -join ',')+' (not touched)')
  Note 'RECOVERY_OK root Chrome9223 restarted, cookies preserved'
} catch {
  Note ('ERROR '+$_.Exception.Message)
  throw
} finally {
  if($script:chromeWasStopped -and -not $script:chromeRestarted){
    try {
      $remaining=@(FindRoots)
      if($remaining.Count -eq 0) {
        Enable-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction SilentlyContinue | Out-Null
        Start-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction SilentlyContinue
        Note 'RECOVERY FALLBACK: requested TT Chrome Auto start'
      }
    }catch{Note ('RECOVERY FALLBACK FAILED '+$_.Exception.Message)}
  }
  RestoreTasks
  foreach($name in @('TTiTTularesDedicatedListener.ps1','TTendenciasDedicatedListener.ps1','TT-LocalWatchdog.ps1')){
    if($script:previousManagers.Contains($name) -or $script:chromeWasStopped){
      try{RestartManager $name}catch{Note ('MANAGER RESTART FAILED '+$name+' '+$_.Exception.Message)}
    }
  }
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
  Note ('REPORT '+$log)
}
