# TT-LocalWatchdog.ps1
# Mantiene vivos listeners TT, auto-updater y Chrome CDP tras reinicios o caídas.
# watchdog-v12-telegram-safe-heal-chat-recovery
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
  $ok=$false
  try{
    $r=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -TimeoutSec 3
    $ok=[bool]$r.webSocketDebuggerUrl
  }catch{}
  if($ok){return}
  try{
    & schtasks.exe /Query /TN "TT Chrome Auto" 1>$null 2>$null
    if($LASTEXITCODE -eq 0){
      & schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
      Log "CHROME AUTO REQUESTED"
    }else{Log "CHROME TASK MISSING"}
  }catch{Log "CHROME AUTO ERROR :: $($_.Exception.Message)"}
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
      [string]$_.url -like "https://chatgpt.com/*"
    }).Count
  }catch{return -1}
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
    EnsureInternetRecovery
    EnsureRemoteTelegramHeal
    # Los trabajos REQUESTED permanecen en GitHub durante la recuperación.
    # Nunca reiniciar Chrome ni un bridge que siga enviando una imagen.
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  try{[void][TTKeepAwake]::SetThreadExecutionState(0x80000000)}catch{}
  try{if($script:InstanceHandle){$script:InstanceHandle.Dispose()}}catch{}
}
})
  if($requested.Count -eq 0){return $true}
  $now=[DateTimeOffset]::UtcNow
  try{
    $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/editorial-queue.json"
    $queue=Invoke-RestMethod -Uri ($url+"?t="+$now.ToUnixTimeMilliseconds()) -TimeoutSec 10 -Headers @{"Cache-Control"="no-cache, no-store"}
  }catch{
    Log "REMOTE EDITORIAL DEFERRED request=$Request reason=queue-fetch-error"
    return $false
  }
  $overdue=@()
  foreach($item in @($queue.items)){
    $eid=[string]$item.id
    $status=[string]$item.status
    if($requested -notcontains $eid -or $status -notin @("preparing","update")){continue}
    try{
      $since=[DateTimeOffset]::Parse([string]$item.requested_at)
      if(($now-$since).TotalMinutes -lt 20){continue}
    }catch{continue}
    $overdue+= $eid
  }
  if($overdue.Count -eq 0){
    Log "REMOTE EDITORIAL ALREADY RESOLVED request=$Request"
    return $true
  }
  $task=$null
  foreach($name in @("TTendencias Local Ready","TTendencias Local")){
    try{
      $candidate=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      if($candidate){$task=$candidate;break}
    }catch{}
  }
  if(-not $task){
    Log "REMOTE EDITORIAL DEFERRED request=$Request reason=scheduled-task-missing"
    return $false
  }
  if([string]$task.State -ne "Ready"){
    Log "REMOTE EDITORIAL DEFERRED request=$Request reason=task-$([string]$task.State)"
    return $false
  }
  try{
    # If the ordinary timer just started the editorial task, let that pass
    # finish before considering a duplicate Autocorregir wakeup.
    $details=Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction Stop
    if($details.LastRunTime -gt [datetime]::MinValue -and
       ((Get-Date)-$details.LastRunTime).TotalMinutes -lt 4){
      Log "REMOTE EDITORIAL DEFERRED request=$Request reason=recent-scheduled-run"
      return $false
    }
  }catch{}
  try{
    Start-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
    Log "REMOTE EDITORIAL TRIGGERED request=$Request task=$($task.TaskName) ids=$($overdue -join ',')"
    return $true
  }catch{
    Log "REMOTE EDITORIAL DEFERRED request=$Request reason=task-start-failed"
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
    EnsureInternetRecovery
    EnsureRemoteTelegramHeal
    # Los trabajos REQUESTED permanecen en GitHub durante la recuperación.
    # Nunca reiniciar Chrome ni un bridge que siga enviando una imagen.
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  try{[void][TTKeepAwake]::SetThreadExecutionState(0x80000000)}catch{}
  try{if($script:InstanceHandle){$script:InstanceHandle.Dispose()}}catch{}
}
