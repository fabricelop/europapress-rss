#requires -Version 5.1
<#
TTActualidad scoped cold restart. Never restarts Windows, ordinary Chrome,
Chrome 9234, SeLoRecordamos, FabCalendar or Cloudflare.
Requires elevation. User-requested restart: active unsent drafts in the dedicated
Chrome 9223 may be lost. GitHub queues and persistent Chrome credentials remain.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$base='C:\TTiTTulares'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $env:LOCALAPPDATA ('TT_Recuperacion\TTActualidad-Restart-'+$stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$log=Join-Path $backup 'restart.log'
function Say([string]$msg){
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' TT_RESTART '+$msg
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
function Roots([int]$port){
  return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop | Where-Object {
    [string]$_.CommandLine -match ('--remote-debugging-port(?:=|\s+)'+$port+'(?:\s|$)') -and
    [string]$_.CommandLine -notmatch '(?:^|\s)--type='
  })
}
function Managers(){
 return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
  $_.Name -in @('powershell.exe','pwsh.exe') -and
  [int]$_.ProcessId -ne $PID -and
  [string]$_.CommandLine -match '(?i)-File\s+"?C:\\TTiTTulares\\(?:TTiTTularesDedicatedListener|TTendenciasDedicatedListener|TT-LocalWatchdog|TT-AutoUpdater|TTiTTularesMobileChatTriggerListener|TTendenciasMobileChatTriggerListener)[.]ps1(?:["\s]|$)'
 })
}
function Nodes(){
 return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
  [string]$_.CommandLine -match '(?i)(?:[\\/]Ejecutar[.]js|[\\/]TT-Editorial-Guard[.]js|[\\/]TT-Editorial-Tab-Watch[.]js|[\\/](?:TTiTTulares|TTendencias)ImageBridge[.]js)'
 })
}
function PortReady(){
 try{$j=Invoke-RestMethod 'http://127.0.0.1:9223/json/version' -TimeoutSec 4 -ErrorAction Stop;return [bool]$j.webSocketDebuggerUrl}catch{return $false}
}
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){throw 'Abre PowerShell como administrador. Sin cambios.'}
$roots=@(Roots 9223)
if($roots.Count -ne 1){throw ('Chrome dedicado 9223 no es único: roots='+$roots.Count+'. Sin cambios.')}
$root=$roots[0]
$cmd=[string]$root.CommandLine
if($cmd -notmatch '(?i)--user-data-dir=(?:"(?<quoted>[^"]+)"|(?<bare>\S+))'){throw 'Perfil Chrome sin identificación segura. Sin cambios.'}
$profile=if($Matches.quoted){$Matches.quoted}else{$Matches.bare}
$profile=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($profile))
if($profile -notmatch '(?i)(?:^|[\\/])ChromeAuto(?:[\\/]|$)' -and
   $profile -notlike ($base+'\*')){throw ('Perfil Chrome 9223 no dedicado: '+$profile+'. Sin cambios.')}
$profileDirArg=[regex]::Match($cmd,'(?i)--profile-directory=(?:"([^"]+)"|(\S+))')
$profileName=if($profileDirArg.Success){if($profileDirArg.Groups[1].Success){$profileDirArg.Groups[1].Value}else{$profileDirArg.Groups[2].Value}}else{'Default'}
if($profileName -match '[\\/]|[.][.]'){throw 'Perfil Chrome inesperado. Sin cambios.'}
$session=Join-Path $profile $profileName
if(-not(Test-Path $session)){throw ('Falta directorio de perfil '+$session+'. Sin cambios.')}
$chromeTask=Get-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
if($chromeTask.State -eq 'Disabled'){throw 'TT Chrome Auto deshabilitado. Sin cambios.'}
$before9234=@(Roots 9234|ForEach-Object ProcessId)
$taskNames=@('TTiTTulares Local Ready','TTendencias Local Ready','TTiTTulares Local','TTendencias Local','TT Chrome Auto')
$changedTasks=New-Object 'System.Collections.Generic.List[string]'
$wasManagers=@(Managers)
$managerNames=@($wasManagers | ForEach-Object {
 $line=[string]$_.CommandLine
 foreach($name in @('TT-LocalWatchdog.ps1','TT-AutoUpdater.ps1','TTiTTularesDedicatedListener.ps1','TTendenciasDedicatedListener.ps1','TTiTTularesMobileChatTriggerListener.ps1','TTendenciasMobileChatTriggerListener.ps1')){
  if($line -match [regex]::Escape($name)){$name;break}
 }
}|Sort-Object -Unique)
$mutex=New-Object System.Threading.Mutex($false,'Local\TTActualidadScopedColdRestart')
$got=$false;$stoppedChrome=$false;$startedChrome=$false
try {
 try{$got=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$got=$true}
 if(-not $got){throw 'Otro reinicio TTActualidad en curso.'}
 Say ('BEGIN Chrome9223 pid='+$root.ProcessId+' Chrome9234 roots='+($before9234 -join ','))
 Say ('BACKUP '+$backup)
 Say 'WARNING unsent drafts or in-progress responses in Chrome9223 can be lost'
 # Suspend only TT-specific schedulers, preserving originally disabled tasks.
 foreach($name in $taskNames){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if($task -and $task.State -ne 'Disabled'){
   Disable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
   $changedTasks.Add($name)
   if($name -ne 'TT Chrome Auto'){try{Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue}catch{}}
   Say ('TASK_PAUSED '+$name)
  }
 }
 foreach($p in @(Managers)){
  try{Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop;Say ('MANAGER_STOPPED pid='+$p.ProcessId)}catch{Say ('MANAGER_STOP_WARNING pid='+$p.ProcessId)}
 }
 foreach($p in @(Nodes)){
  try{Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop;Say ('NODE_STOPPED pid='+$p.ProcessId)}catch{Say ('NODE_STOP_WARNING pid='+$p.ProcessId)}
 }
 Start-Sleep -Seconds 1
 $still=@(Roots 9223)
 if($still.Count -ne 1 -or [int]$still[0].ProcessId -ne [int]$root.ProcessId){throw 'Chrome9223 cambió de proceso; reinicio abortado.'}
 # Preserve a copy of session files; cookies and account profile are never cleared.
 $sessionBackup=Join-Path $backup 'sessions'
 New-Item -ItemType Directory -Path $sessionBackup -Force | Out-Null
 Say ('CHROME9223_STOP pid='+$root.ProcessId)
 & "$env:WINDIR\System32\taskkill.exe" /PID $root.ProcessId /T /F | Out-Null
 if($LASTEXITCODE -ne 0){throw ('taskkill error '+$LASTEXITCODE)}
 $stoppedChrome=$true
 foreach($i in 1..15){if(@(Roots 9223).Count -eq 0){break};Start-Sleep -Seconds 1}
 if(@(Roots 9223).Count){throw 'Chrome9223 no se detuvo.'}
 foreach($name in @('Sessions','Current Session','Last Session','Current Tabs','Last Tabs')){
  $p=Join-Path $session $name
  if(Test-Path -LiteralPath $p){Move-Item -LiteralPath $p -Destination (Join-Path $sessionBackup $name) -ErrorAction Stop;Say ('SESSION_BACKED_UP '+$name)}
 }
 # Old tracked target IDs are meaningless after a fresh Chrome process.
 $watch=Join-Path $base 'editorial-tab-watch'
 if(Test-Path $watch){
  $back=Join-Path $backup 'editorial-tab-watch'
  New-Item -ItemType Directory -Path $back -Force | Out-Null
  Get-ChildItem -LiteralPath $watch -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object{
   if($_.Name -match '^[a-f0-9-]{16,80}[.]json$'){Move-Item -LiteralPath $_.FullName -Destination (Join-Path $back $_.Name) -ErrorAction Stop}
  }
  Say 'STALE_EDITORIAL_TRACKING_ARCHIVED'
 }
 # Preserve image pin files for audit; image listeners revalidate them on startup.
 foreach($name in @('ttittulares-image-tab.json','ttendencias-image-tab.json')){
  $p=Join-Path $base $name
  if(Test-Path $p){Copy-Item $p (Join-Path $backup $name) -ErrorAction SilentlyContinue}
 }
 if($changedTasks.Contains('TT Chrome Auto')){
  Enable-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop | Out-Null
  [void]$changedTasks.Remove('TT Chrome Auto')
 }
 Start-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
 for($i=0;$i -lt 35;$i++){if(PortReady){$startedChrome=$true;break};Start-Sleep -Seconds 2}
 if(-not $startedChrome){throw 'Chrome9223 no respondió; restauración de procesos en finally.'}
 Say ('CHROME9223_STARTED root='+(@(Roots 9223|ForEach-Object ProcessId) -join ','))
} catch {Say ('ERROR '+$_.Exception.Message);throw} finally {
 if($stoppedChrome -and -not $startedChrome -and @(Roots 9223).Count -eq 0){
  try{
   if((Get-ScheduledTask -TaskName 'TT Chrome Auto').State -eq 'Disabled'){Enable-ScheduledTask -TaskName 'TT Chrome Auto' | Out-Null}
   Start-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
   Say 'CHROME9223_FALLBACK_START_REQUESTED'
  }catch{Say ('CHROME9223_FALLBACK_ERROR '+$_.Exception.Message)}
 }
 foreach($name in $changedTasks){
  try{Enable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null;Say ('TASK_RESTORED '+$name)}
  catch{Say ('TASK_RESTORE_ERROR '+$name+' '+$_.Exception.Message)}
 }
 foreach($name in $managerNames){
  $existing=@(Managers | Where-Object { [string]$_.CommandLine -match [regex]::Escape($name) })
  if($existing.Count -gt 0){continue}
  $source=Join-Path $base $name
  if(Test-Path $source){
   try{
    $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$source+'"'
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $base -WindowStyle Hidden -PassThru -ErrorAction Stop
    Say ('MANAGER_STARTED '+$name+' pid='+$p.Id)
   }catch{Say ('MANAGER_START_ERROR '+$name+' '+$_.Exception.Message)}
  }
 }
 $after9234=@(Roots 9234|ForEach-Object ProcessId)
 Say ('CHROME9234_UNTOUCHED before='+($before9234 -join ',')+' after='+($after9234 -join ','))
 Say ('FINAL Chrome9223_ready='+(PortReady)+' backup='+$backup)
 if($got){try{$mutex.ReleaseMutex()}catch{}}
 $mutex.Dispose()
 Say ('REPORT '+$log)
}
