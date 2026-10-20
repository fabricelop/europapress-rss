#requires -Version 5.1
<#
TT Chrome 9223 lifecycle cleanup installer v1.
Updates the editorial tab watcher, verified-idle home cleanup, watchdog,
and auto-updater without killing Chrome, changing image bridges, or deleting
TT queues/cookies. Existing listeners keep running.
#>
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$base='C:\TTiTTulares'
if(-not(Test-Path -LiteralPath (Join-Path $base 'Ejecutar.js'))){throw 'Falta C:\TTiTTulares\Ejecutar.js; sin cambios'}
$backupDir=Join-Path $env:LOCALAPPDATA ('TT_Recuperacion\Lifecycle-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$log=Join-Path $backupDir 'install.log'
function Note([string]$message){
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' TT_LIFECYCLE '+$message
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
function LocalManagers([string]$name) {
  $escaped=[regex]::Escape($name)
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @('powershell.exe','pwsh.exe') -and
    [string]$_.CommandLine -match ('(?i)(?:^|\s)-File\s+"?C:\\TTiTTulares\\'+$escaped+'(?:["\s]|$)')
  })
}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$manifest=@(
  @{Name='TT-Editorial-Tab-Watch.js';Type='js';Marker='ADOPT_CONVERSATION'},
  @{Name='TT-Chrome9223-Safe-Prune.js';Type='js';Marker='VERIFIED_IDLE_MS'},
  @{Name='TT-LocalWatchdog.ps1';Type='ps';Marker='watchdog-v14-editorial-tab-lifecycle'},
  @{Name='TT-AutoUpdater.ps1';Type='ps';Marker='TT-Chrome9223-Safe-Prune.js'}
)
$mutex=New-Object System.Threading.Mutex($false,'Local\TTChrome9223LifecycleInstaller')
$locked=$false
$watchdogWasRunning=$false
$updaterWasRunning=$false
$watcherWasRunning=$false
$replacements=New-Object 'System.Collections.Generic.List[object]'
try {
  try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
  if(-not $locked){throw 'Otra instalación del ciclo de vida ya está en curso'}
  Note ('BEGIN check_only='+$CheckOnly)
  $current=(Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue)
  if($current){Note ('MEMORY committed_GB='+[math]::Round([double]$current.CommittedBytes/1GB,2))}
  $remote=@{}
  foreach($entry in $manifest){
    $name=[string]$entry.Name
    $target=Join-Path $base $name
    $source=Join-Path $backupDir ($name+'.validated.'+[string]$entry.Type)
    $uri='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/'+$name+'?t='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $source -TimeoutSec 25 -ErrorAction Stop
    $text=[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)
    if($text.Length -lt 1000 -or -not $text.Contains([string]$entry.Marker)){
      throw ('Origen inesperado '+$name+'; no se instala nada')
    }
    if($entry.Type -eq 'js'){
      & $node --check $source 2>&1 | Out-Null
      if($LASTEXITCODE -ne 0){throw ('Sintaxis JS no válida '+$name)}
    }else{
      $tokens=$null;$parseErrors=$null
      [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$parseErrors)|Out-Null
      if($parseErrors.Count -gt 0){throw ('Sintaxis PowerShell no válida '+$name+': '+$parseErrors[0].Message)}
    }
    $before=if(Test-Path -LiteralPath $target){(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}else{''}
    $after=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $remote[$name]=@{Source=$source;Target=$target;Changed=($before -ne $after);Before=$before;After=$after}
    Note ('VALIDATED '+$name+' update='+($before -ne $after))
  }
  $runnerPath=Join-Path $base 'Ejecutar.js'
  $runnerText=[IO.File]::ReadAllText($runnerPath,[Text.Encoding]::UTF8)
  $runnerPatched=$runnerText.Contains('TT_EDITORIAL_TAB_WATCH_V1')
  Note ('RUNNER_REGISTER_HOOK='+$runnerPatched)
  if($CheckOnly){Note 'CHECK_ONLY no processes or files changed';return}
  # Stop only tiny maintenance daemons; never stop TT editorial/image listeners,
  # Chrome 9223/9234, bridge workers, or scheduled jobs.
  $updaterList=@(LocalManagers 'TT-AutoUpdater.ps1')
  $watchdogList=@(LocalManagers 'TT-LocalWatchdog.ps1')
  $updaterWasRunning=$updaterList.Count -gt 0
  $watchdogWasRunning=$watchdogList.Count -gt 0
  foreach($p in @($watchdogList)+@($updaterList)){
    try{
      Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
      Note ('MAINTENANCE_DAEMON_PAUSED pid='+$p.ProcessId)
    }catch{Note ('MAINTENANCE_DAEMON_PAUSE_WARNING pid='+$p.ProcessId+' '+$_.Exception.Message)}
  }
  $watchers=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
    [string]$_.CommandLine -match '(?i)TT-Editorial-Tab-Watch[.]js' -and [string]$_.CommandLine -match '--daemon'
  })
  $watcherWasRunning=$watchers.Count -gt 0
  foreach($p in $watchers){
    try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop;Note ('TAB_WATCHER_PAUSED pid='+$p.ProcessId)}
    catch{Note ('TAB_WATCHER_PAUSE_WARNING '+$_.Exception.Message)}
  }
  Start-Sleep -Milliseconds 800
  foreach($entry in $manifest){
    $name=[string]$entry.Name
    $item=$remote[$name]
    if(-not $item.Changed){continue}
    if(Test-Path -LiteralPath $item.Target){
      $original=Join-Path $backupDir ($name+'.before')
      Copy-Item -LiteralPath $item.Target -Destination $original -ErrorAction Stop
      $replacements.Add(@{Target=$item.Target;Backup=$original;Existed=$true})
    }else{$replacements.Add(@{Target=$item.Target;Backup='';Existed=$false})}
    $temp=$item.Target+'.lifecycle.tmp'
    Copy-Item -LiteralPath $item.Source -Destination $temp -Force -ErrorAction Stop
    Move-Item -LiteralPath $temp -Destination $item.Target -Force -ErrorAction Stop
    if((Get-FileHash -LiteralPath $item.Target -Algorithm SHA256).Hash -ne $item.After){
      throw ('La copia no coincide '+$name)
    }
    Note ('INSTALLED '+$name)
  }
  if(-not $runnerPatched){
    # The hook patch is intentionally NOT attempted while Ejecutar.js is live.
    # Install it only when no sender is active; it has backup and rollback.
    $senders=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { [string]$_.CommandLine -match '[\\/]Ejecutar[.]js' })
    if($senders.Count){
      Note ('RUNNER_PATCH_DEFERRED active_senders='+$senders.Count)
    }else{
      $patch=Join-Path $backupDir 'Patch-Ejecutar-Tab-Watch.ps1'
      $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/Patch-Ejecutar-Tab-Watch.ps1'
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $patch -TimeoutSec 25 -ErrorAction Stop
      Copy-Item -LiteralPath (Join-Path $base 'TT-Editorial-Tab-Watch.js') -Destination (Join-Path $backupDir 'TT-Editorial-Tab-Watch.js') -Force
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $patch 2>&1 | ForEach-Object {Note ('RUNNER_PATCH '+[string]$_)}
      if($LASTEXITCODE -ne 0){Note ('RUNNER_PATCH_NOT_CONFIRMED exit='+$LASTEXITCODE)}
      else{Note 'RUNNER_HOOK_INSTALLED'}
    }
  }
  Note 'INSTALL_OK Chrome 9223/9234 not restarted or killed'
} catch {
  Note ('INSTALL_ERROR '+$_.Exception.Message)
  $changes=@($replacements)
  [array]::Reverse($changes)
  foreach($change in $changes){
    try{
      if($change.Existed){Copy-Item -LiteralPath $change.Backup -Destination $change.Target -Force -ErrorAction Stop}
      else{Remove-Item -LiteralPath $change.Target -Force -ErrorAction SilentlyContinue}
      Note ('ROLLBACK '+$change.Target)
    }catch{Note ('ROLLBACK_WARNING '+$_.Exception.Message)}
  }
  throw
} finally {
  foreach($name in @('TT-AutoUpdater.ps1','TT-LocalWatchdog.ps1')){
    $wasRunning=if($name -eq 'TT-AutoUpdater.ps1'){$updaterWasRunning}else{$watchdogWasRunning}
    if($wasRunning){
      $already=@(LocalManagers $name)
      if($already.Count -eq 0){
        try {
          $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
            '-File',('"'+(Join-Path $base $name)+'"')
          ) -WorkingDirectory $base -WindowStyle Hidden -PassThru -ErrorAction Stop
          Note ('MAINTENANCE_DAEMON_RESTARTED '+$name+' pid='+$p.Id)
        }catch{Note ('MAINTENANCE_RESTART_WARNING '+$name+' '+$_.Exception.Message)}
      }
    }
  }
  if($watcherWasRunning){
    $existing=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { [string]$_.CommandLine -match 'TT-Editorial-Tab-Watch[.]js' -and [string]$_.CommandLine -match '--daemon' })
    if($existing.Count -eq 0){
      $jobs=Join-Path $base 'editorial-tab-watch'
      if((Test-Path -LiteralPath $jobs) -and @(Get-ChildItem -LiteralPath $jobs -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0){
        try {
          $p=Start-Process -FilePath $node -ArgumentList @((Join-Path $base 'TT-Editorial-Tab-Watch.js'),'--daemon') -WorkingDirectory $base -WindowStyle Hidden -PassThru -ErrorAction Stop
          Note ('TAB_WATCHER_RESTARTED pid='+$p.Id)
        }catch{Note ('TAB_WATCHER_RESTART_WARNING '+$_.Exception.Message)}
      }
    }
  }
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
  Note ('REPORT '+$log)
}
