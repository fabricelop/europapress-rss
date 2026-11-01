#requires -Version 5.1
<#
TTActualidad 2026-11-01: conservative recovery after manually closing Chrome.
Read-only by default; -Apply STARTS missing components only.
Never kills processes, browsers, tasks, locks, image jobs or cached sessions.
Never modifies browser profiles, queues, users' photos or Telegram baselines.
#>
[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$base = 'C:\TTiTTulares'
$lock = New-Object System.Threading.Mutex($false,'Local\TTChromeClosedSafeRecoveryV1')
$owner = $false
$warnings = New-Object System.Collections.Generic.List[string]
function Say([string]$status, [string]$item, [string]$detail){
  Write-Output ("TT_SAFE_RECOVERY {0} {1} {2}" -f $status, $item, $detail)
}
function Warn([string]$item,[string]$detail){
  $warnings.Add($item+': '+$detail)
  Say 'PENDING' $item $detail
}
function CheckPort([int]$port){
  try {
    $result = Invoke-RestMethod -Uri ("http://127.0.0.1:"+$port+"/json/version") -TimeoutSec 4 -ErrorAction Stop
    return [bool]$result.webSocketDebuggerUrl
  } catch { return $false }
}
function BrowserRoots([int]$port){
  $p = [string]$port
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
      Where-Object {
        [string]$_.CommandLine -match ('--remote-debugging-port(?:=|\s+)'+$p+'(?:\s|$)') -and
        [string]$_.CommandLine -notmatch '(?:^|\s)--type='
      })
  } catch {
    Warn ('CHROME'+$p) ('Unable to check root process: '+$_.Exception.Message)
    return @('UNKNOWN')
  }
}
function ManagerCount([string]$file){
  try {
    return @(
      Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -in @('powershell.exe','pwsh.exe') -and
        [string]$_.CommandLine -like ('*\' + $file + '*') -and
        [int]$_.ProcessId -ne $PID
      }
    ).Count
  } catch { Warn $file ('Cannot inspect processes: '+$_.Exception.Message);return -1 }
}
function EnsureManager([string]$file){
  $script = Join-Path $base $file
  $count = ManagerCount $file
  if($count -lt 0){return}
  if($count -eq 1){Say 'OK' $file 'one process running';return}
  if($count -gt 1){Warn $file ('DUPLICATES '+$count+'; no process stopped');return}
  if(-not(Test-Path -LiteralPath $script)){
    Warn $file 'local script missing; no remote installation'
    return
  }
  $tokens = $null; $errors = $null
  [Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){Warn $file 'script syntax invalid; no launch';return}
  if(-not $Apply){Say 'WOULD_START' $file 'missing process';return}
  try{
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
      '-WindowStyle','Hidden','-File',('"' + $script + '"')
    ) -WorkingDirectory $base -WindowStyle Hidden -PassThru -ErrorAction Stop
    Start-Sleep -Milliseconds 1300
    $p.Refresh()
    if($p.HasExited){
      Warn $file ('started then exited; PID '+$p.Id+' exit='+$p.ExitCode)
    }else{
      Say 'STARTED' $file ('PID='+$p.Id)
    }
  }catch{
    Warn $file ('start failed: '+$_.Exception.Message)
  }
}
function EnsureChrome9223 {
  if(CheckPort 9223){Say 'OK' 'CHROME9223' 'CDP responds';return}
  $roots = @(BrowserRoots 9223)
  if($roots.Count -gt 0){
    Warn 'CHROME9223' ('root exists but CDP is unavailable (or ownership unclear); NO browser kill/duplicate launch')
    return
  }
  $task = Get-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction SilentlyContinue
  if(-not $task){Warn 'CHROME9223' 'TT Chrome Auto task missing';return}
  if([string]$task.State -eq 'Disabled'){Warn 'CHROME9223' 'task disabled; left unchanged';return}
  if([string]$task.State -eq 'Running'){Warn 'CHROME9223' 'startup task already running';return}
  $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
  if($info -and $info.LastRunTime -gt [datetime]::MinValue -and
      ((Get-Date)-$info.LastRunTime).TotalSeconds -lt 240){
    Warn 'CHROME9223' 'startup attempted recently; wait for watchdog, no duplicate launch'
    return
  }
  if(-not $Apply){Say 'WOULD_START' 'CHROME9223' 'TT Chrome Auto';return}
  try {
    Start-ScheduledTask -TaskName 'TT Chrome Auto' -ErrorAction Stop
    Start-Sleep -Seconds 4
    if(CheckPort 9223){Say 'STARTED' 'CHROME9223' 'CDP verified'}
    else {Warn 'CHROME9223' 'task requested but CDP not yet verified'}
  }catch{Warn 'CHROME9223' ('task launch failed: '+$_.Exception.Message)}
}
function CheckChrome9234 {
  if(CheckPort 9234){Say 'OK' 'TTIMAGES9234' 'isolated Chrome CDP responds';return}
  $roots=@(BrowserRoots 9234)
  if($roots.Count -gt 0){
    Warn 'TTIMAGES9234' 'isolated Chrome root exists but CDP unavailable: manual inspection required'
    return
  }
  # TT Image Relay capture and Telegram tasks are NOT browser launchers.
  # Starting them can duplicate photo delivery; do not auto-run them.
  Warn 'TTIMAGES9234' 'isolated Chrome is absent. Do not run capture/Telegram task as a substitute for browser startup.'
}
function EnsureContinuousTask([string]$name){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if(-not $task){Warn $name 'not installed';return}
  if([string]$task.State -eq 'Disabled'){Warn $name 'disabled; not modified';return}
  if([string]$task.State -eq 'Running'){Say 'OK' $name 'running';return}
  if(-not $Apply){Say 'WOULD_START' $name 'present but not running';return}
  try { Start-ScheduledTask -TaskName $name -ErrorAction Stop
        Say 'REQUESTED' $name 'task start requested, not proof of delivery'
  }catch{Warn $name ('cannot start: '+$_.Exception.Message)}
}
try {
  try{$owner=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owner=$true}
  if(-not $owner){Say 'BLOCKED' 'INSTANCE' 'another safe recovery is running';return}
  Say 'BEGIN' 'MODE' $(if($Apply){'APPLY (start missing only)'}else{'INSPECT ONLY'})
  if(-not(Test-Path -LiteralPath (Join-Path $base 'Ejecutar.js'))){
    Warn 'INSTALLATION' 'C:\TTiTTulares\Ejecutar.js absent; no process changes'
    return
  }
  # Do not bring back ordinary Chrome; only dedicated 9223.
  EnsureChrome9223
  EnsureManager 'TT-LocalWatchdog.ps1'
  EnsureManager 'TT-AutoUpdater.ps1'
  EnsureManager 'TTiTTularesDedicatedListener.ps1'
  EnsureManager 'TTendenciasDedicatedListener.ps1'
  CheckChrome9234
  foreach($name in @('TT Image Relay - Telegram v2',
                     'TT Image Relay - Botones v2',
                     'TTImages - AutoRecovery Viewer')){
    $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if(-not $t){Warn $name 'task missing';continue}
    $info=Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    Say 'TASK' $name ('state='+$t.State+' last_result='+$info.LastTaskResult)
    # Never trigger a capture, publishing, button action or guardian arbitrarily.
  }
  EnsureContinuousTask 'SeLoRecordamos-Telegram'
  EnsureContinuousTask 'SeLoRecordamos-Watchdog'
  foreach($name in @('SeLoRecordamos-Search','SeLoRecordamos-Published',
                     'TTiTTulares Local','TTendencias Local')){
    $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if($t){Say 'TASK' $name ('state='+$t.State+' (schedule preserved)')}
    else{Warn $name 'task missing'}
  }
  Say 'FINAL' 'CHROME9223' $(if(CheckPort 9223){'OK'}else{'NOT_VERIFIED'})
  Say 'FINAL' 'TTIMAGES9234' $(if(CheckPort 9234){'OK'}else{'NOT_VERIFIED'})
  Say 'FINAL' 'MANAGERS' ('TT='+ (ManagerCount 'TTiTTularesDedicatedListener.ps1')+
    ' Trends='+(ManagerCount 'TTendenciasDedicatedListener.ps1')+
    ' Watchdog='+(ManagerCount 'TT-LocalWatchdog.ps1'))
  Say 'SUMMARY' 'WARNINGS' ([string]$warnings.Count)
} finally {
  if($owner){try{$lock.ReleaseMutex()}catch{}}
  $lock.Dispose()
}
