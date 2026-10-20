# TT-LocalWatchdog.ps1
# Mantiene vivos listeners TT, auto-updater y Chrome CDP tras reinicios o caídas.
# watchdog-v14-editorial-tab-lifecycle
param([int]$IntervalSeconds=60)
$ErrorActionPreference="Continue"
$BaseDir="C:\TTiTTulares"
$LogPath=Join-Path $BaseDir "tt-local-watchdog.log"
$StartupDir=[Environment]::GetFolderPath("Startup")

try{
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TTKeepAwake {
  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint esFlags);
}
"@ -ErrorAction SilentlyContinue
  [void][TTKeepAwake]::SetThreadExecutionState(0x80000001)
}catch{}


function Log([string]$Text){
  try{
    New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
    Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$Text) -Encoding UTF8
  }catch{}
}
function Enter-ProcessInstance([string]$LockPath) {
  # El SO libera el handle al salir o terminar el proceso; el fichero no es un PID.
  # No borrar este fichero: su presencia no implica que exista un propietario.
  try {
    $script:InstanceHandle = [System.IO.File]::Open(
      $LockPath, [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    return $true
  } catch [System.IO.IOException] {
    return $false
  }
}

function PsProcs([string]$Pattern){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and [string]$_.CommandLine -like $Pattern
  })
}
function StartHiddenPs([string]$Script,[string]$Tag){
  if(-not (Test-Path -LiteralPath $Script)){Log "MISSING $Tag :: $Script";return $null}
  try{
    $out=Join-Path $BaseDir ($Tag+".watchdog.out.log")
    $err=Join-Path $BaseDir ($Tag+".watchdog.err.log")
    $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Script) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    Start-Sleep -Milliseconds 800
    $p.Refresh()
    if($p.HasExited){Log "START FAILED $Tag exit=$($p.ExitCode)";return $null}
    Log "STARTED $Tag pid=$($p.Id)"
    return $p
  }catch{Log "START ERROR $Tag :: $($_.Exception.Message)";return $null}
}
function EnsureSingle([string]$Pattern,[string]$Script,[string]$Tag){
  $rows=@(PsProcs $Pattern)
  if($rows.Count -eq 0){[void](StartHiddenPs $Script $Tag);return}
  if($rows.Count -gt 1){
    $keep=$rows|Sort-Object CreationDate,ProcessId|Select-Object -First 1
    foreach($p in $rows){if($p.ProcessId -ne $keep.ProcessId){try{Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}}
    Log "DEDUP $Tag keep=$($keep.ProcessId) removed=$($rows.Count-1)"
  }
}
function EnsureStartup([string]$Name,[string]$Script){
  try{
    if(-not $StartupDir){return}
    $path=Join-Path $StartupDir $Name
    $content='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Script+'"'
    if(-not (Test-Path $path) -or (Get-Content $path -Raw -ErrorAction SilentlyContinue) -ne $content){
      Set-Content -LiteralPath $path -Value $content -Encoding ASCII
      Log "STARTUP ENSURED $Name"
    }
  }catch{Log "STARTUP ERROR $Name :: $($_.Exception.Message)"}
}
function EnsureChrome{
  # watchdog-v13: fail closed; don't relaunch a living Chrome 9223 on CDP timeout.
  # Check IPv4 and IPv6, since Windows can bind to either loopback address.
  foreach($hostAddress in @("127.0.0.1","[::1]")){
    try{
      $r=Invoke-RestMethod -Uri ("http://"+$hostAddress+":9223/json/version") -TimeoutSec 4
      if($r -and $r.webSocketDebuggerUrl){return}
    }catch{}
  }

  # A running browser is not proof of a healthy CDP endpoint, but attempting
  # another launch makes things worse. Leave recovery to a controlled repair.
  $browserRoots=@()
  try{
    $browserRoots=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop | Where-Object {
      [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)' -and
      [string]$_.CommandLine -notmatch '(?:^|\s)--type='
    })
  }catch{
    Log ("CHROME PROCESS CHECK FAILED; relaunch blocked :: "+$_.Exception.Message)
    return
  }
  if($browserRoots.Count -gt 0){
    $now=[DateTimeOffset]::UtcNow
    if(-not $script:LastChromeAliveWarningAt -or ($now-$script:LastChromeAliveWarningAt).TotalMinutes -ge 10){
      $script:LastChromeAliveWarningAt=$now
      Log ("CHROME CDP UNREACHABLE BUT BROWSER ALIVE; relaunch blocked pid="+[string]$browserRoots[0].ProcessId)
    }
    return
  }

  # Even with no Chrome root, use Task Scheduler's persisted LastRunTime
  # to avoid duplicate startups across watchdog instances.
  try{
    $task=Get-ScheduledTask -TaskName "TT Chrome Auto" -ErrorAction Stop
    $info=Get-ScheduledTaskInfo -TaskName "TT Chrome Auto" -ErrorAction Stop
    if([string]$task.State -eq "Running"){return}
    if($info.LastRunTime -gt [datetime]::MinValue -and
       ((Get-Date)-$info.LastRunTime).TotalSeconds -lt 300){return}
    & schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
    if($LASTEXITCODE -eq 0){Log "CHROME AUTO REQUESTED (no root, 5min cooldown)"}
    else{Log "CHROME AUTO FAILED exit="+$LASTEXITCODE}
  }catch{
    Log ("CHROME TASK CHECK FAILED; no launch :: "+$_.Exception.Message)
  }
}
# Recuperación segura tras caída de Internet: un proceso vivo puede conservar
# conexiones/snapshots obsoletos y no volver a consumir imágenes REQUESTED.
# Reiniciar SOLAMENTE los listeners, y nunca durante un bridge o envío en curso.
$script:NetworkWasOnline=$null
$script:NetworkOkCount=0
$script:NetworkFailCount=0
$script:ReconnectPending=$false
$script:ReconnectCause=""
$script:StartupQueueChecked=$false
$script:LastReconnectAt=[DateTimeOffset]::MinValue

function Test-ControlNetwork{
  try{
    $response=Invoke-WebRequest -UseBasicParsing -Method Head -Uri "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/README.md" -TimeoutSec 7
    return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
  }catch{return $false}
}
function Has-PendingImageQueue{
  foreach($url in @(
    "https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttittulares-run-trigger-v2/ttittulares/image-runs/index.json",
    "https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/image-runs/index.json"
  )){
    try{
      $separator=if($url.Contains("?")){"&"}else{"?"}
      $doc=Invoke-RestMethod -Uri ($url+$separator+"t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 7 -Headers @{"Cache-Control"="no-cache"}
      if($doc -and $doc.jobs -and @($doc.jobs).Count -gt 0){return $true}
    }catch{Log ("RECONNECT QUEUE CHECK ERROR :: "+$_.Exception.Message)}
  }
  return $false
}
function Test-ChatOperationBusy{
  try{
    $busy=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object{
      $_.Name -in @("node.exe","powershell.exe","pwsh.exe") -and
      [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge\.js|Ejecutar\.js'
    })
    return ($busy.Count -gt 0)
  }catch{
    # No matar procesos si no conseguimos comprobar operaciones activas.
    return $true
  }
}
# Chrome 9223 housekeeping: only empty root tabs, never conversations.
# The pruning helper is installed separately and is dry-run by default.
$script:LastChromeTabHousekeepingAt=[DateTimeOffset]::MinValue
function EnsureChromeTabHousekeeping{
  $now=[DateTimeOffset]::UtcNow
  if(($now-$script:LastChromeTabHousekeepingAt).TotalMinutes -lt 5){return}
  $script:LastChromeTabHousekeepingAt=$now
  $helper=Join-Path $BaseDir "TT-Chrome9223-Safe-Prune.js"
  if(-not (Test-Path -LiteralPath $helper)){return}
  if(Test-ChatOperationBusy){return}

  $targets=$null
  foreach($endpoint in @("http://127.0.0.1:9223","http://[::1]:9223")){
    try{
      $targets=@(Invoke-RestMethod -Uri ($endpoint+"/json/list") -TimeoutSec 5)
      break
    }catch{}
  }
  if($null -eq $targets){return}
  $homes=@($targets | Where-Object {
    [string]$_.type -eq "page" -and [string]$_.url -eq "https://chatgpt.com/"
  })
  if($homes.Count -lt 8){return}

  try{
    $already=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
      Where-Object { [string]$_.CommandLine -like "*TT-Chrome9223-Safe-Prune.js*" })
    if($already.Count -gt 0){return}
    $node=Get-Command node.exe -ErrorAction Stop
    $stdout=Join-Path $BaseDir "tt-chrome-tab-housekeeping.log"
    $stderr=Join-Path $BaseDir "tt-chrome-tab-housekeeping.err.log"
    $p=Start-Process -FilePath $node.Source -ArgumentList @($helper,"--apply") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -ErrorAction Stop
    Log ("CHROME TAB HOUSEKEEPING START pid="+$p.Id+" idle_home_candidates="+$homes.Count)
  }catch{
    Log ("CHROME TAB HOUSEKEEPING DEFERRED :: "+$_.Exception.Message)
  }
}

function Recover-ListenersAfterReconnect{
  if(-not $script:ReconnectPending){return}
  $now=[DateTimeOffset]::UtcNow
  if(($now-$script:LastReconnectAt).TotalMinutes -lt 10){return}
  if(Test-ChatOperationBusy){
    Log "RECONNECT DEFERRED reason=chat-or-image-bridge-active"
    return
  }
  # Puede existir una orden aceptada pero todavía sin lanzar: limitar la
  # intervención a procesos PowerShell; nunca tocar Chrome, Node ni los locks.
  $targets=@(
    @{Name="TTiTTularesDedicatedListener.ps1";Tag="ttittulares-listener"},
    @{Name="TTendenciasDedicatedListener.ps1";Tag="ttendencias-listener"}
  )
  foreach($target in $targets){
    $path=Join-Path $BaseDir $target.Name
    $found=@(PsProcs ("*"+$target.Name+"*"))
    foreach($proc in $found){
      try{Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
    }
    Start-Sleep -Milliseconds 700
    [void](StartHiddenPs $path $target.Tag)
  }
  $script:LastReconnectAt=$now
  $script:ReconnectPending=$false
  Log ("RECONNECT RECOVERY DONE cause="+$script:ReconnectCause+" listeners=2")
}
function EnsureInternetRecovery{
  $online=Test-ControlNetwork
  if(-not $online){
    $script:NetworkOkCount=0
    $script:NetworkFailCount++
    if($script:NetworkFailCount -ge 2 -and $script:NetworkWasOnline -ne $false){
      $script:NetworkWasOnline=$false
      Log "NETWORK OFFLINE detected; queues remain untouched"
    }
    return
  }
  $script:NetworkFailCount=0
  $script:NetworkOkCount++
  if($script:NetworkOkCount -lt 2){return}
  if($script:NetworkWasOnline -eq $false){
    $script:ReconnectPending=$true
    $script:ReconnectCause="network-reconnected"
    Log "NETWORK ONLINE again; safe listener resynchronization requested"
  }
  $script:NetworkWasOnline=$true
  # Si el watchdog acaba de reinstalarse/despertar online y había listeners
  # anteriores atascados, una cola real pendiente permite recuperarlos.
  if(-not $script:StartupQueueChecked){
    $script:StartupQueueChecked=$true
    if(-not $script:ReconnectPending -and (Has-PendingImageQueue)){
      $existing=@(PsProcs "*TTiTTularesDedicatedListener.ps1*")+
                @(PsProcs "*TTendenciasDedicatedListener.ps1*")
      $old=@($existing | Where-Object{
        try{([datetime]::UtcNow-([datetime]$_.CreationDate).ToUniversalTime()).TotalMinutes -gt 4}catch{$false}
      })
      if($old.Count -gt 0){
        $script:ReconnectPending=$true
        $script:ReconnectCause="startup-pending-queue"
        Log "RECONNECT startup: pending images with old listeners"
      }
    }
  }
  Recover-ListenersAfterReconnect
}


# El boton privado Autocorregir deposita una marca en GitHub. La orden
# no contiene scripts ni comandos: la accion local es fija y segura.
$script:RemoteHealStatePath=Join-Path $BaseDir "tt-remote-heal-last.json"
$script:RemoteHealSeenId=""
$script:RemoteHealLastPoll=[DateTimeOffset]::MinValue
$script:RemoteHealLastTabOpen=[DateTimeOffset]::MinValue
try{
  if(Test-Path -LiteralPath $script:RemoteHealStatePath){
    $previous=Get-Content -LiteralPath $script:RemoteHealStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:RemoteHealSeenId=[string]$previous.request_id
  }
}catch{ Log "REMOTE HEAL STATE READ WARNING" }

function Get-ChatCdpTabCount{
  try{
    $targets=@(Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 4 -Headers @{"Cache-Control"="no-cache"})
    return @($targets | Where-Object {
      [string]$_.type -eq "page" -and $_.webSocketDebuggerUrl -and
      [string]$_.url -match '(?i)^https://chatgpt[.]com/(?:$|[?#]|c/|g/|project/|images(?:/|$))'
    }).Count
  }catch{return -1}
}
function EnsureOverdueTrendsEditorialRetry($Signal,[string]$Request){
  # Only existing local TTendencias scheduled tasks can be started.
  # No commands from GitHub execute on this PC; only IDs are considered.
  $wanted=@($Signal.editorial_retry.ttendencias)
  if($wanted.Count -eq 0){return $true}
  $now=[DateTimeOffset]::UtcNow
  try{
    $uri="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/editorial-queue.json"
    $q=Invoke-RestMethod -Uri ($uri+"?t="+$now.ToUnixTimeMilliseconds()) -TimeoutSec 10 -Headers @{"Cache-Control"="no-cache, no-store"}
  }catch{
    Log "REMOTE EDITORIAL DEFERRED request=$Request queue-not-reachable"
    return $false
  }
  $due=@()
  foreach($item in @($q.items)){
    if(-not ($wanted -contains ([string]$item.id))){continue}
    if(@("preparing","update") -notcontains ([string]$item.status)){continue}
    try{
      $stamp=[DateTimeOffset]::Parse([string]$item.requested_at)
      if(($now-$stamp).TotalMinutes -ge 20){$due+=([string]$item.id)}
    }catch{}
  }
  if($due.Count -eq 0){return $true}
  $task=$null
  foreach($name in @("TTendencias Local Ready","TTendencias Local")){
    try{$t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; if($t){$task=$t;break}}catch{}
  }
  if(-not $task -or ([string]$task.State -ne "Ready")){
    Log "REMOTE EDITORIAL DEFERRED request=$Request local-task-busy-or-missing"
    return $false
  }
  try{
    $info=Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction Stop
    if($info.LastRunTime -gt [datetime]::MinValue -and ((Get-Date)-$info.LastRunTime).TotalMinutes -lt 4){return $false}
  }catch{}
  try{
    Start-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
    Log "REMOTE EDITORIAL TRIGGERED request=$Request task=$($task.TaskName) count=$($due.Count)"
    return $true
  }catch{
    Log "REMOTE EDITORIAL DEFERRED request=$Request local-task-error"
    return $false
  }
}

function EnsureRemoteTelegramHeal{
  $now=[DateTimeOffset]::UtcNow
  if(($now-$script:RemoteHealLastPoll).TotalSeconds -lt 55){return}
  $script:RemoteHealLastPoll=$now
  try{
    $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/telegram/tt-local-recovery-request.json"
    $signal=Invoke-RestMethod -Uri ($url+"?t="+$now.ToUnixTimeMilliseconds()) -TimeoutSec 10 -Headers @{"Cache-Control"="no-cache, no-store"}
  }catch{return}
  if([string]$signal.action -ne "recover_chat_tab_if_missing"){return}
  $request=[string]$signal.request_id
  if($request -notmatch '^[a-f0-9]{32}$' -or $request -eq $script:RemoteHealSeenId){return}
  try{
    $when=[DateTimeOffset]::Parse([string]$signal.requested_at)
    $age=($now-$when).TotalHours
    if($age -lt -0.1 -or $age -gt 24){return}
  }catch{return}
  if(Test-ChatOperationBusy){
    Log "REMOTE HEAL DEFERRED request=$request reason=image-or-chat-operation-active"
    return
  }

  $count=Get-ChatCdpTabCount
  if($count -lt 0){
    EnsureChrome
    Log "REMOTE HEAL DEFERRED request=$request reason=chrome-cdp-not-ready"
    return
  }
  if($count -eq 0){
    if(($now-$script:RemoteHealLastTabOpen).TotalSeconds -lt 60){return}
    $script:RemoteHealLastTabOpen=$now
    try{
      $tab=Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:9223/json/new?"+[uri]::EscapeDataString("https://chatgpt.com/")) -TimeoutSec 8
      Log "REMOTE HEAL CHAT TAB REQUESTED request=$request target=$([string]$tab.id)"
    }catch{
      Log "REMOTE HEAL CHAT TAB ERROR request=$request :: $($_.Exception.Message)"
      return
    }
    $deadline=(Get-Date).AddSeconds(12)
    do{
      Start-Sleep -Seconds 2
      $count=Get-ChatCdpTabCount
    }while($count -eq 0 -and (Get-Date) -lt $deadline)
    if($count -lt 1){
      Log "REMOTE HEAL CHAT TAB PENDING request=$request"
      return
    }
  }

  # Recuperar listeners sin interrumpir un bridge de imagen activo.
  $script:ReconnectPending=$true
  $script:ReconnectCause="telegram-autocorregir"
  Recover-ListenersAfterReconnect
  if($script:ReconnectPending){
    Log "REMOTE HEAL LISTENER RECOVERY DEFERRED request=$request"
    return
  }
  # Recheck main before waking the existing TTendencias local editorial job.
  if(-not (EnsureOverdueTrendsEditorialRetry $signal $request)){return}
  try{
    @{request_id=$request;completed_at=$now.ToString("o")} |
      ConvertTo-Json -Compress |
      Set-Content -LiteralPath $script:RemoteHealStatePath -Encoding UTF8 -ErrorAction Stop
    $script:RemoteHealSeenId=$request
    Log "REMOTE HEAL COMPLETE request=$request chat_tabs=$count"
  }catch{
    Log "REMOTE HEAL STATE ERROR request=$request :: $($_.Exception.Message)"
  }
}

# Recuperar SOLO el listener TTiTTulares si una imagen de Listas
# sigue en REQUESTED sin recogida. No se toca Chrome ni TTImages.
$script:LastTTitImageRescueProbe=[DateTimeOffset]::MinValue
function EnsureTTitRequestedImageRecovery{
  $now=[DateTimeOffset]::UtcNow
  if(($now-$script:LastTTitImageRescueProbe).TotalMinutes -lt 10){return}
  $script:LastTTitImageRescueProbe=$now
  if(Test-ChatOperationBusy){return}
  $base="https://raw.githubusercontent.com/fabricelop/europapress-rss/"
  $control=$base+"control/ttittulares-run-trigger-v2/ttittulares/image-runs/"
  $preparedUrl=$base+"main/ttittulares/prepared.json"
  try{
    $headers=@{"Cache-Control"="no-cache, no-store";"User-Agent"="TTit-Watchdog-Pending-Images-v1"}
    $idx=Invoke-RestMethod -Uri ($control+"index.json?t="+$now.ToUnixTimeMilliseconds()) -Headers $headers -TimeoutSec 12
    $prepared=Invoke-RestMethod -Uri ($preparedUrl+"?t="+$now.ToUnixTimeMilliseconds()) -Headers $headers -TimeoutSec 12
    $eligible=@{}
    foreach($row in @($prepared.items)){
      $eid=[string]$row.event_id
      if($eid -match '^[a-fA-F0-9]{12}$' -and $row.tweet -and
         -not [string]::IsNullOrWhiteSpace([string]$row.tweet.text) -and
         -not [string]::IsNullOrWhiteSpace([string]$row.tweet.remate)){
        $eligible[$eid]=$true
      }
    }
    $stalled=$null
    foreach($entry in @($idx.jobs)){
      $id=[string]$entry.target_id
      if(-not $eligible.ContainsKey($id)){continue}
      if($id -notmatch '^[a-fA-F0-9]{12}$'){continue}
      $age=0
      try{$age=($now-[DateTimeOffset]::Parse([string]$entry.requested_at)).TotalMinutes}catch{continue}
      if($age -lt 8 -or $age -gt 720){continue}
      $job=Invoke-RestMethod -Uri ($control+"jobs/"+$id+".json?t="+$now.ToUnixTimeMilliseconds()) -Headers $headers -TimeoutSec 12
      if(([string]$job.command_id -eq [string]$entry.command_id) -and
         ([string]$job.status).ToUpperInvariant() -eq "REQUESTED" -and
         -not $job.pc_picked_up_at -and -not $job.pc_launched_at){
        $stalled=$entry;break
      }
    }
    if(-not $stalled){return}
    $listenerPath=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
    $live=@(PsProcs "*TTiTTularesDedicatedListener.ps1*")
    if($live.Count -gt 0){
      $young=@($live|Where-Object{
        try{($now-([DateTimeOffset]$_.CreationDate)).TotalMinutes -lt 3}catch{$true}
      })
      if($young.Count -gt 0){return}
    }
    if(Test-ChatOperationBusy){return}
    Log ("TTIT IMAGE REQUESTED STALLED job="+[string]$stalled.target_id+
         " command="+[string]$stalled.command_id+" restart-listener-only=1")
    foreach($proc in $live){
      try{Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
    }
    Start-Sleep -Milliseconds 900
    [void](StartHiddenPs $listenerPath "ttittulares-image-rescue")
    Log ("TTIT IMAGE RESCUE START REQUESTED job="+[string]$stalled.target_id)
  }catch{
    Log ("TTIT IMAGE RESCUE PROBE ERROR :: "+$_.Exception.Message)
  }
}


# Chrome 9223 resource telemetry. No automatic browser kill or cache deletion:
# image jobs may be running on ChatGPT even after an ACK.
$script:LastChromePressureProbeAt=[DateTimeOffset]::MinValue
function MeasureChrome9223Pressure {
  $now=[DateTimeOffset]::UtcNow
  if(($now-$script:LastChromePressureProbeAt).TotalMinutes -lt 10){return}
  $script:LastChromePressureProbeAt=$now
  try{
    $all=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop)
    $roots=@($all | Where-Object {
      [string]$_.CommandLine -match '--remote-debugging-port(?:=|\\s+)9223(?:\\s|$)' -and
      [string]$_.CommandLine -notmatch '(?:^|\\s)--type=' -and
      [string]$_.CommandLine -match 'ChromeAuto'
    })
    if($roots.Count -ne 1){
      Log ("CHROME 9223 TELEMETRY UNCERTAIN roots="+$roots.Count+"; no action")
      return
    }
    $rootPid=[int]$roots[0].ProcessId
    $group=@($all | Where-Object {
      [int]$_.ProcessId -eq $rootPid -or [int]$_.ParentProcessId -eq $rootPid
    })
    $renderers=@($group | Where-Object { [string]$_.CommandLine -match '(?:^|\\s)--type=renderer(?:\\s|$)' }).Count
    [long]$ram=0
    foreach($p in $group){ $ram += [long]$p.WorkingSetSize }
    $ramMB=[math]::Round($ram / 1MB, 0)
    if($renderers -ge 40 -or $ramMB -ge 6144){
      Log ("CHROME 9223 RESOURCE PRESSURE pid=$rootPid renderers=$renderers processes="+$group.Count+" apparent_ram_mb=$ramMB no_auto_restart=1")
    }
  }catch{
    Log ("CHROME 9223 TELEMETRY UNAVAILABLE; no action :: "+$_.Exception.Message)
  }
}

function EnsureScheduledTasks{
  foreach($name in @(
    "TT Chrome Auto","TTiTTulares Local","TTendencias Local",
    "SeLoRecordamos-Telegram","SeLoRecordamos-Search","SeLoRecordamos-Published","SeLoRecordamos-Watchdog"
  )){
    try{
      $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      if($task -and $task.State -eq "Disabled"){
        Enable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue|Out-Null
        Log "TASK ENABLED $name"
      }
    }catch{}
  }
  try{
    $slr=Get-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
    if($slr -and $slr.State -ne "Running"){
      Start-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
      Log "SLR TELEGRAM LISTENER REQUESTED"
    }
  }catch{}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
if (-not (Enter-ProcessInstance (Join-Path $BaseDir "tt-watchdog.instance.lock"))) { exit 0 }

$tt=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$tr=Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$up=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$self=Join-Path $BaseDir "TT-LocalWatchdog.ps1"
EnsureStartup "TT Automation Watchdog.cmd" $self
EnsureStartup "TTiTTulares Mobile Trigger Listener.cmd" $tt
EnsureStartup "TTendencias Mobile Trigger Listener.cmd" $tr
EnsureStartup "TT Auto Updater.cmd" $up

Log "WATCHDOG START pid=$PID interval=$IntervalSeconds"
try{
  while($true){
    EnsureSingle "*TTiTTularesDedicatedListener.ps1*" $tt "ttittulares-listener"
    EnsureSingle "*TTendenciasDedicatedListener.ps1*" $tr "ttendencias-listener"
    EnsureSingle "*TT-AutoUpdater.ps1*" $up "tt-auto-updater"
    EnsureScheduledTasks
    EnsureChrome
    MeasureChrome9223Pressure
    EnsureChromeTabHousekeeping
    EnsureInternetRecovery
    EnsureRemoteTelegramHeal
    EnsureTTitRequestedImageRecovery
    # Los trabajos REQUESTED permanecen en GitHub durante la recuperación.
    # Nunca reiniciar Chrome ni un bridge que siga enviando una imagen.
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  try{[void][TTKeepAwake]::SetThreadExecutionState(0x80000000)}catch{}
  try{if($script:InstanceHandle){$script:InstanceHandle.Dispose()}}catch{}
}
