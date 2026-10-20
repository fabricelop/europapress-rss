#requires -Version 5.1
<#
TT Chrome Memory Safe Repair v1
Reports committed memory, Chrome process trees and CDP tabs.
Repairs the editorial tab watcher and safely prunes only verified empty idle
9223 home tabs. Never terminates a Chrome process or touches 9234 tabs,
TTImages capture, TTActualidad workers, queues, listeners or scheduled jobs.
#>
[CmdletBinding()]
param([switch]$InspectOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = 'C:\TTiTTulares'
$repoBase = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/'
$reportDir = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$report = Join-Path $reportDir ('chrome-memory-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
function Say([string]$line) {
  Write-Host $line
  Add-Content -LiteralPath $report -Value $line -Encoding UTF8
}
function MB([double]$bytes) { return [math]::Round($bytes/1MB,1) }
Say ('TT_CHROME_MEMORY_V1 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' inspect_only=' + $InspectOnly)
try {
  $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
  $commit = [double]$memory.CommittedBytes
  $limit = [double]$memory.CommitLimit
  if ($limit -gt 0) { Say ('MEMORY commit_GB=' + [math]::Round($commit/1GB,2) + ' limit_GB=' + [math]::Round($limit/1GB,2) + ' percent=' + [math]::Round(100*$commit/$limit,1)) }
} catch { Say ('MEMORY_COUNTER_UNAVAILABLE ' + $_.Exception.Message) }
try {
  $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  Say ('PAGEFILE system_managed=' + [string]$computer.AutomaticManagedPagefile)
  foreach($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
    Say ('PAGEFILE ' + $pf.Name + ' allocated_MB=' + $pf.AllocatedBaseSize + ' peak_used_MB=' + $pf.PeakUsage)
  }
} catch { Say ('PAGEFILE_INFO_UNAVAILABLE ' + $_.Exception.Message) }
$chrome = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop)
$script:byChromePid = @{}
foreach($p in $chrome) { $script:byChromePid[[int]$p.ProcessId] = $p }
function RootPid($p) {
  $current = $p
  for($k=0;$k -lt 40;$k++) {
    $parent = [int]$current.ParentProcessId
    if(-not $script:byChromePid.ContainsKey($parent)) { return [int]$current.ProcessId }
    $current = $script:byChromePid[$parent]
  }
  return [int]$current.ProcessId
}
Say ('CHROME total_processes=' + $chrome.Count)
$groups = @($chrome | Group-Object { RootPid $_ })
foreach($g in @($groups | Sort-Object { ($_.Group | Measure-Object -Property PrivatePageCount -Sum).Sum } -Descending)) {
  $rootId = [int]$g.Name
  $root = $script:byChromePid[$rootId]
  $command = if($root) { [string]$root.CommandLine } else { '' }
  $kind = if($command -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'){'TT_CDP_9223'} elseif($command -match '--remote-debugging-port(?:=|\s+)9234(?:\s|$)'){'TTIMAGES_CDP_9234'} else {'OTHER_OR_UNIDENTIFIED'}
  $sum = ($g.Group | Measure-Object -Property PrivatePageCount -Sum).Sum
  Say ('GROUP ' + $kind + ' root_pid=' + $rootId + ' processes=' + $g.Count + ' private_GB=' + [math]::Round([double]$sum/1GB,2))
}
foreach($p in @($chrome | Sort-Object { [double]$_.PrivatePageCount } -Descending | Select-Object -First 12)) {
  Say ('TOP pid=' + $p.ProcessId + ' root=' + (RootPid $p) + ' private_MB=' + (MB ([double]$p.PrivatePageCount)))
}
foreach($port in @(9223,9234)) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:'+ $port +'/json/list') -TimeoutSec 6 -ErrorAction Stop
    $targets = @(ConvertFrom-Json -InputObject ([string]$response.Content))
    $pages = @($targets | Where-Object { [string]$_.type -eq 'page' })
    $home = @($pages | Where-Object { [string]$_.url -eq 'https://chatgpt.com/' })
    $conv = @($pages | Where-Object { [string]$_.url -match '^https://chatgpt\.com/c/' })
    $gallery = @($pages | Where-Object { [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)' })
    Say ('CDP port=' + $port + ' targets=' + $targets.Count + ' pages=' + $pages.Count + ' home=' + $home.Count + ' conversations=' + $conv.Count + ' galleries=' + $gallery.Count)
  } catch { Say ('CDP port=' + $port + ' unavailable=' + $_.Exception.Message) }
}
try {
  $guardian = Get-ScheduledTask -TaskName 'TTImages - AutoRecovery Viewer' -ErrorAction SilentlyContinue
  if ($guardian) {
    $info = Get-ScheduledTaskInfo -TaskName $guardian.TaskName -ErrorAction SilentlyContinue
    Say ('GUARDIAN state=' + $guardian.State + ' last=' + $info.LastRunTime + ' result=' + $info.LastTaskResult)
  }
  $gl = Join-Path $env:LOCALAPPDATA 'TTImageRelay\auto-recovery-v1.log'
  if(Test-Path -LiteralPath $gl) {
    foreach($line in @(Get-Content -LiteralPath $gl -Tail 12 -ErrorAction SilentlyContinue)) { Say ('GUARDIAN_LOG ' + $line) }
  }
} catch { Say ('GUARDIAN_CHECK_ERROR ' + $_.Exception.Message) }
try {
  $events = @(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector';Id=2004;StartTime=(Get-Date).AddHours(-12)} -MaxEvents 4 -ErrorAction SilentlyContinue)
  foreach($evt in $events) { Say ('MEMORY_EXHAUSTION event=' + $evt.Id + ' at=' + $evt.TimeCreated) }
} catch {}
if($InspectOnly) {
  Say ('INSPECT_ONLY no files, tabs or processes modified')
  Say ('REPORT ' + $report)
  return
}
$tmp = Join-Path $env:TEMP ('TT-MemorySafe-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  $watcher = Join-Path $tmp 'TT-Editorial-Tab-Watch.js'
  $patch = Join-Path $tmp 'Patch-Ejecutar-Tab-Watch.ps1'
  $prune = Join-Path $tmp 'TT-Chrome9223-Safe-Prune.js'
  foreach($name in @('TT-Editorial-Tab-Watch.js','Patch-Ejecutar-Tab-Watch.ps1','TT-Chrome9223-Safe-Prune.js')) {
    Invoke-WebRequest -UseBasicParsing -Uri ($repoBase + $name) -OutFile (Join-Path $tmp $name) -TimeoutSec 25 -ErrorAction Stop
  }
  $source = [IO.File]::ReadAllText($watcher,[Text.Encoding]::UTF8)
  if(-not $source.Contains('OLD_JOB_POLL_MS') -or -not $source.Contains('closed_after_completed_response') -or
     $source.Contains("stopTracking(f,'unverified_after_3_hours_LEFT_OPEN')")) {
    throw 'Unexpected watcher version; no repair applied'
  }
  $pruneSource = [IO.File]::ReadAllText($prune,[Text.Encoding]::UTF8)
  if(-not $pruneSource.Contains('MIN_KEEP_HOME=3') -or -not $pruneSource.Contains('checkBusy()') -or
     -not $pruneSource.Contains('if(!APPLY)')) { throw 'Unexpected conservative-prune version' }
  $node = (Get-Command node.exe -ErrorAction Stop).Source
  & $node --check $watcher 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0) { throw 'Watcher JS syntax invalid' }
  & $node --check $prune 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0) { throw 'Prune JS syntax invalid' }
  $tokens=$null; $parseErrors=$null
  [Management.Automation.Language.Parser]::ParseFile($patch,[ref]$tokens,[ref]$parseErrors) | Out-Null
  if($parseErrors.Count -gt 0) { throw 'Patcher PS syntax invalid' }
  $runner = Join-Path $base 'Ejecutar.js'
  if(-not(Test-Path -LiteralPath $runner)) {
    Say 'WATCHER_NOT_INSTALLED no C:\TTiTTulares\Ejecutar.js; no files touched'
  } else {
    $runnerSrc = [IO.File]::ReadAllText($runner,[Text.Encoding]::UTF8)
    $busy = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
      [string]$_.CommandLine -match '[\\/]Ejecutar[.]js'
    })
    if($runnerSrc.Contains('TT_EDITORIAL_TAB_WATCH_V1')) {
      $dest = Join-Path $base 'TT-Editorial-Tab-Watch.js'
      $install = $true
      if(Test-Path -LiteralPath $dest) {
        $localHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        $sourceHash = (Get-FileHash -LiteralPath $watcher -Algorithm SHA256).Hash
        $install = $localHash -ne $sourceHash
      }
      if($install) {
        if(Test-Path -LiteralPath $dest) {
          Copy-Item -LiteralPath $dest -Destination ($dest + '.before-memory-fix-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak') -ErrorAction Stop
        }
        $tempDest = $dest + '.memory-fix.new.js'
        Copy-Item -LiteralPath $watcher -Destination $tempDest -Force -ErrorAction Stop
        Move-Item -LiteralPath $tempDest -Destination $dest -Force -ErrorAction Stop
        Say 'WATCHER_UPDATED no Chrome, queues or listeners changed'
      } else { Say 'WATCHER_ALREADY_CURRENT' }
    } elseif($busy.Count -gt 0) {
      Say ('WATCHER_PATCH_DEFERRED active_Ejecutar=' + $busy.Count)
    } else {
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $patch 2>&1 | ForEach-Object { Say ('PATCH ' + $_) }
      if($LASTEXITCODE -ne 0) { Say ('WATCHER_PATCH_NOT_CONFIRMED exit=' + $LASTEXITCODE) }
      else { Say 'WATCHER_PATCH_INSTALLED' }
    }
    $installed = Join-Path $base 'TT-Editorial-Tab-Watch.js'
    if((Test-Path -LiteralPath $installed) -and ((Get-Content -LiteralPath $installed -Raw -Encoding UTF8).Contains('OLD_JOB_POLL_MS'))) {
      $daemons = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.CommandLine -match 'TT-Editorial-Tab-Watch[.]js' -and [string]$_.CommandLine -match '--daemon'
      })
      foreach($d in $daemons) {
        try { Stop-Process -Id $d.ProcessId -Force -ErrorAction Stop; Say ('WATCHER_OLD_DAEMON_STOPPED pid=' + $d.ProcessId) }
        catch { Say ('WATCHER_RESTART_DEFERRED pid=' + $d.ProcessId) }
      }
      $jobs = Join-Path $base 'editorial-tab-watch'
      if(Test-Path -LiteralPath $jobs) {
        $jobCount = @(Get-ChildItem -LiteralPath $jobs -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        if($jobCount -gt 0) {
          Start-Sleep -Milliseconds 500
          Start-Process -FilePath $node -ArgumentList ('"'+$installed+'" --daemon') -WindowStyle Hidden | Out-Null
          Say ('WATCHER_RESTART_REQUESTED tracked_jobs=' + $jobCount)
        }
      }
    }
  }
  $running = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
    [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge[.]js|[\\/]Ejecutar[.]js'
  })
  if($running.Count -gt 0) {
    Say ('SAFE_PRUNE_DEFERRED active_jobs=' + $running.Count)
  } else {
    Say 'SAFE_PRUNE starting conservative cleanup of empty, idle Chrome 9223 home tabs only'
    & $node $prune --apply 2>&1 | ForEach-Object { Say ('PRUNE ' + $_) }
    Say ('SAFE_PRUNE_EXIT ' + $LASTEXITCODE)
  }
  Say 'REPAIR_END no Chrome process killed; 9234 untouched'
} catch {
  Say ('REPAIR_ERROR ' + $_.Exception.Message)
  throw
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Say ('REPORT ' + $report)
}
