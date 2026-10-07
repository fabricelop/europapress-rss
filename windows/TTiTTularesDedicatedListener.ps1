# TTiTTularesDedicatedListener.ps1
# official-pipeline-restart-token: 2026-10-06-v47-direct-job-first
# compatibility validator: ttittulares-dedicated-v44
# Listener dedicado a TTiTTulares: ejecución editorial oficial + jobs automáticos/manuales de Gag IA.
# No procesa TTendencias. READY se materializa con texto+remate y el tramo visual continúa automáticamente.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$ImageBridge = Join-Path $BaseDir "TTiTTularesImageBridge.js"
$ImageBridgeLockPath = Join-Path $BaseDir "ttittulares-image-bridge.lock.json"
$OtherImageBridgeLockPath = Join-Path $BaseDir "ttendencias-image-bridge.lock.json"
$StatePath = Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$WatchdogPath = Join-Path $BaseDir "TT-LocalWatchdog.ps1"
$LauncherLogPath = Join-Path $BaseDir "titulares.log"
$LaunchConfirmSeconds = 30
$StatusBase = "https://europapress-rss.vercel.app"
$ListenerSnapshotUrl = "$StatusBase/api/ttittulares-run-status?view=listener-snapshot"
$ImageJobUrlBase = "$StatusBase/api/ttittulares-run-status?view=image-job&strong=1&id="
$RunUrl = "$StatusBase/api/ttittulares-run"
$ControlBranch = "control/ttittulares-run-trigger-v2"
$ControlRepoUrl = "https://github.com/fabricelop/europapress-rss.git"
$script:ControlHeadSha = ""
$script:ControlHeadAt = [DateTimeOffset]::MinValue
$DirectImageRefreshSeconds = 60
$script:DirectImageIndexCache = $null
$script:DirectImageIndexAt = [DateTimeOffset]::MinValue
$DirectTriggerRefreshSeconds = 60
$script:DirectTriggerCache = $null
$script:DirectTriggerAt = [DateTimeOffset]::MinValue
$script:LastAckConflict = $null
# Worker version visible in ACK: confirma remotamente que AutoUpdater instaló el listener v31.
$WorkerId = "ttittulares-dedicated-v48"
$PollSeconds = 15
$ClaimRetrySeconds = 38
$MaxTriggerAgeSeconds = 604800
$MaxParallelImageChats = 1
$ImageStaleMinutes = 45
$SnapshotStrongSeconds = 30
$SnapshotCacheSeconds = 12
$script:ListenerSnapshotCache = $null
$script:ListenerSnapshotAt = [DateTimeOffset]::MinValue
$script:LastStrongSnapshotAt = [DateTimeOffset]::MinValue
# v44: no usar mutex de kernel aquí. El reparador y TT-LocalWatchdog
# garantizan una única instancia por CommandLine/PID. Un mutex retenido por una
# instancia oculta impedía arrancar sin dejar stderr ni log.

function Write-Log([string]$Text) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Ensure-LocalWatchdog {
  try {
    $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/TT-LocalWatchdog.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $tmp=$WatchdogPath+".new"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 20
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count -gt 0){throw "Watchdog PowerShell invalido"}
    $changed=$true
    if(Test-Path -LiteralPath $WatchdogPath){
      try{$changed=((Get-FileHash $tmp -Algorithm SHA256).Hash -ne (Get-FileHash $WatchdogPath -Algorithm SHA256).Hash)}catch{}
    }
    Move-Item -LiteralPath $tmp -Destination $WatchdogPath -Force
    $live=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
      ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TT-LocalWatchdog.ps1*"
    })
    if($changed -and $live.Count -gt 0){
      $live|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
      Start-Sleep -Milliseconds 300
      $live=@()
    }
    if($live.Count -eq 0){
      $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$WatchdogPath) -WindowStyle Hidden -PassThru
      Write-Log "WATCHDOG STARTED pid=$($p.Id)"
    }
  } catch {
    Write-Log "WATCHDOG ENSURE ERROR :: $($_.Exception.Message)"
  }
}


function CacheBust([string]$Url) {
  $sep = if ($Url.Contains("?")) { "&" } else { "?" }
  return $Url + $sep + "t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-ControlHeadSha([switch]$Force) {
  $now=[DateTimeOffset]::UtcNow
  # Una sola resolución de rama cada 90 s como máximo. El resto de lecturas
  # usan raw.githubusercontent con SHA inmutable y no consumen REST.
  if($script:ControlHeadSha -and (($now-$script:ControlHeadAt).TotalSeconds -lt 90)){
    return $script:ControlHeadSha
  }
  try{
    $refUrl="https://api.github.com/repos/fabricelop/europapress-rss/git/ref/heads/control/ttittulares-run-trigger-v2"
    $r=Invoke-RestMethod -Uri (CacheBust $refUrl) -Headers @{
      "Accept"="application/vnd.github+json"
      "User-Agent"="TTiTTulares-Control-Head-Anonymous-v46"
      "Cache-Control"="no-cache"
    } -TimeoutSec 12
    $sha=[string]$r.object.sha
    if($sha -match '^[0-9a-fA-F]{40}$'){
      $script:ControlHeadSha=$sha.ToLowerInvariant()
      $script:ControlHeadAt=$now
      return $script:ControlHeadSha
    }
  }catch{
    Write-Log "CONTROL HEAD ANON API WARNING :: $($_.Exception.Message)"
  }
  # Fallback si la cuota anónima del IP también estuviera temporalmente agotada.
  try{
    $git=Get-Command git.exe -ErrorAction SilentlyContinue
    if(-not $git){$git=Get-Command git -ErrorAction SilentlyContinue}
    if($git){
      $oldPrompt=$env:GIT_TERMINAL_PROMPT
      try{
        $env:GIT_TERMINAL_PROMPT="0"
        $line=& $git.Source ls-remote $ControlRepoUrl ("refs/heads/"+$ControlBranch) 2>$null | Select-Object -First 1
      }finally{
        if($null -eq $oldPrompt){Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue}else{$env:GIT_TERMINAL_PROMPT=$oldPrompt}
      }
      if([string]$line -match '^([0-9a-fA-F]{40})\s'){
        $script:ControlHeadSha=$Matches[1].ToLowerInvariant()
        $script:ControlHeadAt=$now
        return $script:ControlHeadSha
      }
    }
  }catch{
    Write-Log "CONTROL HEAD GIT WARNING :: $($_.Exception.Message)"
  }
  return ""
}

function Get-ControlRawUrl([string]$Path,[switch]$ForceHead) {
  $sha=Get-ControlHeadSha -Force:$ForceHead
  $ref=if($sha){$sha}else{$ControlBranch}
  $clean=$Path.TrimStart("/")
  return "https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$ref+"/"+$clean
}

function Read-ListenerSnapshot {
  $now=[DateTimeOffset]::UtcNow
  if($script:ListenerSnapshotCache -and (($now-$script:ListenerSnapshotAt).TotalSeconds -lt $SnapshotCacheSeconds)){
    return $script:ListenerSnapshotCache
  }
  $strong=(($now-$script:LastStrongSnapshotAt).TotalSeconds -ge $SnapshotStrongSeconds)
  $url=$ListenerSnapshotUrl + $(if($strong){"&strong=1"}else{""})
  try{
    $r=Invoke-RestMethod -Uri (CacheBust $url) -Headers @{
      "Cache-Control" = "no-cache"
      "User-Agent" = "TTiTTulares-Dedicated-Listener"
    } -TimeoutSec 12
    if($r -and $r.ok){
      $script:ListenerSnapshotCache=$r
      $script:ListenerSnapshotAt=$now
      if($strong){$script:LastStrongSnapshotAt=$now}
      return $r
    }
  }catch{
    Write-Log "SNAPSHOT ERROR :: $($_.Exception.Message)"
  }
  return $script:ListenerSnapshotCache
}

function Read-TriggerDirect([switch]$Force) {
  $now=[DateTimeOffset]::UtcNow
  if(-not $Force -and $script:DirectTriggerCache -and (($now-$script:DirectTriggerAt).TotalSeconds -lt $DirectTriggerRefreshSeconds)){
    return $script:DirectTriggerCache
  }
  try{
    $parsed=Invoke-RestMethod -Uri (CacheBust (Get-ControlRawUrl "ttittulares/run-now-trigger.json" -ForceHead:$Force)) -Headers @{
      "User-Agent"="TTiTTulares-Dedicated-Listener-DirectTrigger-Raw"
      "Cache-Control"="no-cache, no-store"
      "Pragma"="no-cache"
    } -TimeoutSec 12
    if($parsed -and $parsed.command_id){
      $script:DirectTriggerCache=$parsed
      $script:DirectTriggerAt=$now
      return $parsed
    }
  }catch{
    Write-Log "DIRECT TRIGGER RAW ERROR :: $($_.Exception.Message)"
  }
  return $script:DirectTriggerCache
}

function Read-Trigger {
  $snapshot=$null
  $r=Read-ListenerSnapshot
  if($r -and $r.trigger){$snapshot=$r.trigger}
  $direct=Read-TriggerDirect
  if($direct -and $direct.command_id){
    if(-not $snapshot -or -not $snapshot.command_id){return $direct}
    try{
      $dt=[DateTimeOffset]::Parse([string]$direct.requested_at)
      $st=[DateTimeOffset]::Parse([string]$snapshot.requested_at)
      if($dt -ge $st){return $direct}
    }catch{
      if([string]$direct.command_id -ne [string]$snapshot.command_id){return $direct}
    }
  }
  return $snapshot
}

function Confirm-DirectTriggerCurrent([string]$CommandId){
  try{
    $d=Read-TriggerDirect -Force
    return ($d -and [string]$d.command_id -eq [string]$CommandId)
  }catch{return $false}
}

function Read-AckDirect {
  try{
    return Invoke-RestMethod -Uri (CacheBust (Get-ControlRawUrl "ttittulares/run-ack.json" -ForceHead)) -Headers @{
      "User-Agent"="TTiTTulares-Dedicated-Listener-DirectAck-Raw"
      "Cache-Control"="no-cache, no-store"
      "Pragma"="no-cache"
    } -TimeoutSec 12
  }catch{
    Write-Log "DIRECT ACK RAW ERROR :: $($_.Exception.Message)"
  }
  return $null
}

function Read-ImageIndexDirect([switch]$Force) {
  $now=[DateTimeOffset]::UtcNow
  if(-not $Force -and $script:DirectImageIndexCache -and (($now-$script:DirectImageIndexAt).TotalSeconds -lt $DirectImageRefreshSeconds)){
    return $script:DirectImageIndexCache
  }
  try{
    $parsed=Invoke-RestMethod -Uri (CacheBust (Get-ControlRawUrl "ttittulares/image-runs/index.json" -ForceHead:$Force)) -Headers @{
      "User-Agent"="TTiTTulares-Dedicated-Listener-DirectImageIndex-Raw"
      "Cache-Control"="no-cache, no-store"
      "Pragma"="no-cache"
    } -TimeoutSec 12
    if($parsed){
      $script:DirectImageIndexCache=$parsed
      $script:DirectImageIndexAt=$now
      return $parsed
    }
  }catch{
    Write-Log "DIRECT IMAGE INDEX RAW ERROR :: $($_.Exception.Message)"
  }
  return $script:DirectImageIndexCache
}

function Read-ImageIndex {
  $snapshot=$null
  $r=Read-ListenerSnapshot
  if($r -and $r.image_index){$snapshot=$r.image_index}

  # La pestaña fija ya no depende de Ejecutar.js. Para evitar que un snapshot
  # Vercel obsoleto deje la cola invisible, contrastamos con GitHub como máximo
  # una vez por minuto (<=60 lecturas/h, muy lejos del límite de 5.000/h).
  $direct=Read-ImageIndexDirect
  if($direct -and $direct.jobs){
    if(-not $snapshot -or -not $snapshot.jobs){return $direct}
    try{
      $sj=@($snapshot.jobs);$dj=@($direct.jobs)
      if($dj.Count -gt $sj.Count){return $direct}
      $sLast=$sj|Select-Object -Last 1
      $dLast=$dj|Select-Object -Last 1
      if($dLast -and (-not $sLast -or [string]$dLast.command_id -ne [string]$sLast.command_id)){
        $sd=if($sLast){[DateTimeOffset]::Parse([string]$sLast.requested_at)}else{[DateTimeOffset]::MinValue}
        $dd=[DateTimeOffset]::Parse([string]$dLast.requested_at)
        if($dd -ge $sd){return $direct}
      }
    }catch{
      return $direct
    }
  }
  if($snapshot){return $snapshot}
  if($direct){return $direct}
  return [pscustomobject]@{ jobs = @() }
}

function Read-ImageJobDirect([string]$TargetId) {
  if(-not $TargetId){return $null}
  try{
    $url=Get-ControlRawUrl ("ttittulares/image-runs/jobs/"+[uri]::EscapeDataString($TargetId)+".json")
    return Invoke-RestMethod -Uri (CacheBust $url) -Headers @{
      "User-Agent"="TTiTTulares-Dedicated-Listener-DirectImageJob-Raw"
      "Cache-Control"="no-cache, no-store"
      "Pragma"="no-cache"
    } -TimeoutSec 12
  }catch{
    Write-Log "DIRECT IMAGE JOB RAW ERROR target=$TargetId :: $($_.Exception.Message)"
  }
  return $null
}

function Read-ImageJob([string]$TargetId) {
  if (-not $TargetId) { return $null }

  # v48: Vercel strong=1 es la lectura primaria de cada job, igual que en
  # TTendencias. El índice puede avanzar varias veces durante 90 s; si primero
  # fijamos un SHA de GitHub anterior, el mismo target devuelve un command_id
  # viejo y el listener descarta el REQUESTED actual. RAW GitHub queda solo
  # como fallback si el endpoint fuerte no responde.
  try {
    $doc=Invoke-RestMethod -Uri (CacheBust ($ImageJobUrlBase + [uri]::EscapeDataString($TargetId))) -Headers @{
      "Cache-Control" = "no-cache, no-store"
      "Pragma" = "no-cache"
      "User-Agent" = "TTiTTulares-Dedicated-Listener-v48"
    } -TimeoutSec 12
    if($doc){return $doc}
  } catch {
    Write-Log "IMAGE JOB API WARNING target=$TargetId :: $($_.Exception.Message)"
  }

  $direct=Read-ImageJobDirect $TargetId
  if($direct){return $direct}
  return $null
}

function Load-State {
  if (Test-Path -LiteralPath $StatePath) {
    try { return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return [pscustomobject]@{
    last_command_id = ""
    conflict_command_id = ""
    conflict_first_at = ""
    image_commands = @()
    active_image_commands = @()
    last_chrome_recovery_command_id = ""
    last_chrome_recovery_at = ""
  }
}

function Save-State($State) {
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Ensure-StateFields($State) {
  foreach ($n in @("last_command_id","conflict_command_id","conflict_first_at","last_chrome_recovery_command_id","last_chrome_recovery_at")) {
    if (-not ($State.PSObject.Properties.Name -contains $n)) {
      $State | Add-Member -NotePropertyName $n -NotePropertyValue "" -Force
    }
  }
  if (-not ($State.PSObject.Properties.Name -contains "image_commands")) {
    $State | Add-Member -NotePropertyName image_commands -NotePropertyValue @() -Force
  }
  if (-not ($State.PSObject.Properties.Name -contains "active_image_commands")) {
    $State | Add-Member -NotePropertyName active_image_commands -NotePropertyValue @() -Force
  }
}


function Send-ImageAck([string]$TargetId,[string]$CommandId,[string]$Stage,[string]$Reason = "",[string]$UploadSecretHash = "",[string]$UploadSecret = "") {
  try {
    $body = @{
      task = "image_pc_ack"
      target_id = $TargetId
      command_id = $CommandId
      stage = $Stage
      worker_id = $WorkerId
    }
    if ($Reason) { $body.reason = $Reason }
    if ($UploadSecretHash) { $body.upload_secret_hash = $UploadSecretHash }
    if ($UploadSecret) { $body.upload_secret = $UploadSecret }
    $payload = $body | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $RunUrl -ContentType "application/json" -Body $payload -TimeoutSec 12 | Out-Null
    Write-Log "IMAGE ACK $Stage target=$TargetId command=$CommandId"
    return $true
  } catch {
    Write-Log "IMAGE ACK ERROR $Stage target=$TargetId command=$CommandId :: $($_.Exception.Message)"
    return $false
  }
}

function New-ImageUploadSecret {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes)
}

function Get-Sha256Hex([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
  } finally { $sha.Dispose() }
}

function Ensure-ImageBridgeLatest([string]$NodePath) {
  $tmp = $ImageBridge + ".new"
  try {
    $url = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/TTiTTularesImageBridge.js?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $wc = New-Object System.Net.WebClient
    try {
      $wc.Headers["User-Agent"]="TTiTTulares-image-bridge-refresh-v29"
      $wc.Headers["Cache-Control"]="no-cache"
      $raw = $wc.DownloadData($url)
    } finally {
      $wc.Dispose()
    }
    if (-not $raw -or $raw.Length -lt 1000) { throw "raw bridge vacío/corto" }
    [IO.File]::WriteAllBytes($tmp,$raw)
    $txt = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    foreach ($needle in @(
      'BRIDGE_MODE="capture-only-v28-dead-submit-retry"',
      'BRIDGE_FEATURES="v29-visible-composer-trusted-click-dom-fallback"',
      'ttittulares-run-status?view=image-job&strong=1&id=',
      'imagesAfterMarker'
    )) {
      if (-not $txt.Contains($needle)) { throw "Bridge remoto sin garantía: $needle" }
    }
    & $NodePath --check $tmp *> $null
    if ($LASTEXITCODE -ne 0) { throw "node --check falló en bridge remoto" }
    Move-Item -LiteralPath $tmp -Destination $ImageBridge -Force
    Write-Log "IMAGE BRIDGE REFRESHED source=raw-v29"
    return $true
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Log "IMAGE BRIDGE REFRESH WARNING :: $($_.Exception.Message)"
  }
  if (Test-Path -LiteralPath $ImageBridge) {
    try {
      $txt = Get-Content -LiteralPath $ImageBridge -Raw -Encoding UTF8
      if ($txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"') -and $txt.Contains('BRIDGE_FEATURES="v29-visible-composer-trusted-click-dom-fallback"') -and $txt.Contains('ttittulares-run-status?view=image-job&strong=1&id=')) {
        & $NodePath --check $ImageBridge *> $null
        if ($LASTEXITCODE -eq 0) { Write-Log "IMAGE BRIDGE USING VALID LOCAL FALLBACK"; return $true }
      }
    } catch {}
  }
  Write-Log "IMAGE BRIDGE ERROR no hay bridge v29 válido"
  return $false
}

function Test-ImageBridgeBusy {
  if (-not (Test-Path -LiteralPath $ImageBridgeLockPath)) { return $false }
  try {
    $lock = Get-Content -LiteralPath $ImageBridgeLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pidValue = [int]$lock.pid
    $targetId = [string]$lock.target_id
    $commandId = [string]$lock.command_id
    $p = if($pidValue -gt 0){Get-Process -Id $pidValue -ErrorAction SilentlyContinue}else{$null}
    if ($p) {
      $terminal = $false
      if($targetId){
        $remote = Read-ImageJob $targetId
        if($remote -and [string]$remote.command_id -eq $commandId -and (Is-TerminalImageStatus ([string]$remote.status))){
          $terminal = $true
        }
      }
      $tooOld = $false
      try {
        $started=[DateTimeOffset]::Parse([string]$lock.started_at)
        $tooOld=(([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 12)
      } catch {}
      if($terminal -or $tooOld){
        $isBridge=$false
        try{
          $proc=Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidValue) -ErrorAction SilentlyContinue
          $isBridge=($proc -and [string]$proc.CommandLine -like "*TTiTTularesImageBridge.js*")
        }catch{}
        Write-Log "IMAGE LOCAL LOCK STALE pid=$pidValue command=$commandId target=$targetId terminal=$terminal too_old=$tooOld bridge_pid=$isBridge"
        if($isBridge){try{Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}catch{}}
        Remove-Item -LiteralPath $ImageBridgeLockPath -Force -ErrorAction SilentlyContinue
        return $false
      }
      Write-Log "IMAGE LOCAL LOCK ACTIVE pid=$pidValue command=$commandId target=$targetId"
      return $true
    }
  } catch {}
  Remove-Item -LiteralPath $ImageBridgeLockPath -Force -ErrorAction SilentlyContinue
  return $false
}

function Test-OtherImageBridgeBusy {
  if (-not (Test-Path -LiteralPath $OtherImageBridgeLockPath)) { return $false }
  try {
    $lock = Get-Content -LiteralPath $OtherImageBridgeLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pidValue = [int]$lock.pid
    $p = if($pidValue -gt 0){Get-Process -Id $pidValue -ErrorAction SilentlyContinue}else{$null}
    if($p){
      $tooOld=$false
      try{
        $started=[DateTimeOffset]::Parse([string]$lock.started_at)
        $tooOld=(([DateTimeOffset]::UtcNow-$started).TotalMinutes -gt 12)
      }catch{}
      if(-not $tooOld){ return $true }

      $isOtherBridge=$false
      try{
        $proc=Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidValue) -ErrorAction SilentlyContinue
        $isOtherBridge=($proc -and [string]$proc.CommandLine -like "*TTendenciasImageBridge.js*")
      }catch{}
      if($isOtherBridge){
        Write-Log "IMAGE OTHER LOCK STALE project=ttendencias pid=$pidValue command=$([string]$lock.command_id) target=$([string]$lock.target_id) age_gt_12m=1"
        try{Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}catch{}
        Remove-Item -LiteralPath $OtherImageBridgeLockPath -Force -ErrorAction SilentlyContinue
        return $false
      }
      # PID reutilizado por otro proceso: este lock ya no es válido.
      Remove-Item -LiteralPath $OtherImageBridgeLockPath -Force -ErrorAction SilentlyContinue
      return $false
    }
  } catch {}
  Remove-Item -LiteralPath $OtherImageBridgeLockPath -Force -ErrorAction SilentlyContinue
  return $false
}

function Test-DedicatedChromeCdpHealthy {
  try {
    $v=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/version?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
    if(-not $v -or -not $v.webSocketDebuggerUrl){ return $false }
    $targets=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 4
    $pages=@($targets | Where-Object { [string]$_.type -eq "page" -and $_.webSocketDebuggerUrl })
    if($pages.Count -eq 0){ return $false }
    $chatPages=@($pages | Where-Object {
      $u=[string]$_.url
      $u -like "https://chatgpt.com/*" -or $u -eq "https://chatgpt.com/"
    })
    return ($chatPages.Count -gt 0)
  } catch {
    return $false
  }
}

function Restart-DedicatedChromeCdp([string]$CommandId,[string]$Reason) {
  if(Test-OtherImageBridgeBusy){
    Write-Log "CHROME CDP RECOVERY DEFERRED command=$CommandId reason=ttendencias-image-active"
    return $false
  }
  Write-Log "CHROME CDP RECOVERY START command=$CommandId reason=$Reason"
  try {
    $roots=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.Name -ieq "chrome.exe" -or $_.Name -ieq "msedge.exe") -and
      [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
    })
    foreach($p in $roots){
      try{& taskkill.exe /PID $p.ProcessId /T /F 1>$null 2>$null}catch{}
    }
    Start-Sleep -Seconds 2
    & schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
    $deadline=(Get-Date).AddSeconds(25)
    while((Get-Date) -lt $deadline){
      try{
        $v=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
        if($v.webSocketDebuggerUrl){
          Write-Log "CHROME CDP RECOVERY OK command=$CommandId killed=$($roots.Count)"
          return $true
        }
      }catch{}
      Start-Sleep -Seconds 1
    }
    Write-Log "CHROME CDP RECOVERY FAILED command=$CommandId reason=endpoint-not-ready"
  } catch {
    Write-Log "CHROME CDP RECOVERY ERROR command=$CommandId :: $($_.Exception.Message)"
  }
  return $false
}

function Recover-ChromeCdpFromRecentImageFailure($State,$Index) {
  if(-not $Index -or -not $Index.jobs){ return $false }
  $jobs=@($Index.jobs | Select-Object -Last 10)
  [array]::Reverse($jobs)
  foreach($j in $jobs){
    $target=[string]$j.target_id
    $command=[string]$j.command_id
    if(-not $target -or -not $command){ continue }
    $doc=Read-ImageJob $target
    if(-not $doc -or [string]$doc.command_id -ne $command){ continue }
    if(([string]$doc.status).ToUpperInvariant() -ne "ERROR"){ continue }
    $reason=[string]$doc.message
    if($reason -notmatch 'CDP timeout (Runtime\.evaluate|Page\.navigate)|no mostró compositor|no mostro compositor'){ continue }
    $recent=$false
    try{
      $at=[DateTimeOffset]::Parse([string]$doc.updated_at)
      $recent=(([DateTimeOffset]::UtcNow-$at).TotalMinutes -le 15)
    }catch{}
    if(-not $recent){ continue }
    if([string]$State.last_chrome_recovery_command_id -eq $command){
      try{
        $last=[DateTimeOffset]::Parse([string]$State.last_chrome_recovery_at)
        if(([DateTimeOffset]::UtcNow-$last).TotalMinutes -lt 15){ return $false }
      }catch{}
    }
    if(Test-OtherImageBridgeBusy){
      Write-Log "CHROME CDP RECOVERY WAIT command=$command reason=ttendencias-image-active"
      return $false
    }
    $ok=Restart-DedicatedChromeCdp $command $reason
    $State.last_chrome_recovery_command_id=$command
    $State.last_chrome_recovery_at=[DateTimeOffset]::UtcNow.ToString("o")
    Save-State $State
    return $ok
  }
  return $false
}

function Set-ImageBridgeLock([int]$BridgePid,[string]$CommandId,[string]$TargetId) {
  try {
    @{
      pid=$BridgePid
      command_id=$CommandId
      target_id=$TargetId
      started_at=[DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ImageBridgeLockPath -Encoding UTF8
  } catch {
    Write-Log "IMAGE LOCAL LOCK WARNING :: $($_.Exception.Message)"
  }
}

function Get-ChatTargetSnapshot {
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/list" -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
    $rows = @($targets | Where-Object { [string]$_.type -eq "page" -and [string]$_.url -like "*chatgpt.com*" } | ForEach-Object {
      [pscustomobject]@{ id=[string]$_.id; url=[string]$_.url; title=[string]$_.title }
    })
    if ($rows.Count -eq 0) { return "[]" }
    return ($rows | ConvertTo-Json -Compress)
  } catch {
    Write-Log "IMAGE TARGET SNAPSHOT WARNING :: $($_.Exception.Message)"
    return "[]"
  }
}


function Publish-ImageTargetHint([string]$BeforeSnapshot,[string]$HintPath,[string]$CommandId) {
  try {
    $before=@{}
    try {
      $rows = @($BeforeSnapshot | ConvertFrom-Json)
      foreach($r in $rows){ if($r.id){ $before[[string]$r.id]=$r } }
    } catch {}

    $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
    $pages = @($targets | Where-Object {
      [string]$_.type -eq "page" -and
      [string]$_.url -like "*chatgpt.com*" -and
      $_.webSocketDebuggerUrl
    })

    $candidate = $null
    $new = @($pages | Where-Object { -not $before.ContainsKey([string]$_.id) })
    if($new.Count -eq 1){
      $candidate=$new[0]
    } elseif($new.Count -gt 1){
      $candidate=$new | Sort-Object -Property @{Expression={ if([string]$_.url -like "*/c/*"){0}else{1} }}, @{Expression={ [string]$_.title }} | Select-Object -First 1
    } else {
      $changed=@()
      foreach($p in $pages){
        $id=[string]$p.id
        if(-not $before.ContainsKey($id)){ continue }
        $b=$before[$id]
        if(([string]$b.url -ne [string]$p.url) -or ([string]$b.title -ne [string]$p.title)){
          $changed += $p
        }
      }
      if($changed.Count -eq 1){ $candidate=$changed[0] }
    }

    if($candidate){
      @{
        command_id=$CommandId
        target_id=[string]$candidate.id
        url=[string]$candidate.url
        title=[string]$candidate.title
        captured_at=[DateTimeOffset]::UtcNow.ToString("o")
      } | ConvertTo-Json -Compress | Set-Content -LiteralPath $HintPath -Encoding UTF8
      Write-Log "IMAGE TARGET HANDOFF command=$CommandId target_id=$([string]$candidate.id) url=$([string]$candidate.url)"
      return [string]$candidate.id
    }

    Write-Log "IMAGE TARGET HANDOFF MISS command=$CommandId new=$($new.Count)"
    return $false
  } catch {
    Write-Log "IMAGE TARGET HANDOFF ERROR command=$CommandId :: $($_.Exception.Message)"
    return $false
  }
}

function Start-ImageBridge([string]$CommandId,[string]$TargetId,[string]$UploadSecret,[string]$TargetSnapshot = "[]",[string]$TargetHintPath = "") {
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { Write-Log "IMAGE BRIDGE ERROR node no encontrado"; return $false }
  if (-not (Ensure-ImageBridgeLatest $node.Source)) { return $false }
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $out = Join-Path $BaseDir ("ttittulares-image-bridge-" + $stamp + "-" + $TargetId + ".log")
  $err = Join-Path $BaseDir ("ttittulares-image-bridge-" + $stamp + "-" + $TargetId + ".err.log")
  $old = $env:TT_IMAGE_UPLOAD_SECRET
  $oldTargets = $env:TT_IMAGE_PRELAUNCH_TARGETS_JSON
  $oldHint = $env:TT_IMAGE_TARGET_HINT_FILE
  try {
    $env:TT_IMAGE_UPLOAD_SECRET = $UploadSecret
    $env:TT_IMAGE_PRELAUNCH_TARGETS_JSON = $(if([string]::IsNullOrWhiteSpace($TargetSnapshot)){"[]"}else{$TargetSnapshot})
    if($TargetHintPath){ $env:TT_IMAGE_TARGET_HINT_FILE = $TargetHintPath } else { Remove-Item Env:TT_IMAGE_TARGET_HINT_FILE -ErrorAction SilentlyContinue }
    $p = Start-Process -FilePath $node.Source -ArgumentList @($ImageBridge,$CommandId,$TargetId) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p) { throw "Start-Process no devolvió proceso" }
    Set-ImageBridgeLock $p.Id $CommandId $TargetId
    Write-Log "IMAGE BRIDGE STARTED pid=$($p.Id) target=$TargetId command=$CommandId stdout=$out stderr=$err"
    return $true
  } catch {
    Write-Log "IMAGE BRIDGE START ERROR target=$TargetId command=$CommandId :: $($_.Exception.Message)"
    return $false
  } finally {
    if ($null -eq $old) { Remove-Item Env:TT_IMAGE_UPLOAD_SECRET -ErrorAction SilentlyContinue }
    else { $env:TT_IMAGE_UPLOAD_SECRET = $old }
    if ($null -eq $oldTargets) { Remove-Item Env:TT_IMAGE_PRELAUNCH_TARGETS_JSON -ErrorAction SilentlyContinue }
    else { $env:TT_IMAGE_PRELAUNCH_TARGETS_JSON = $oldTargets }
    if ($null -eq $oldHint) { Remove-Item Env:TT_IMAGE_TARGET_HINT_FILE -ErrorAction SilentlyContinue }
    else { $env:TT_IMAGE_TARGET_HINT_FILE = $oldHint }
  }
}

function Launch-ImageChat([string]$Reason,[string]$Message,[string]$ExpectedMarker) {
  if (-not (Test-Path -LiteralPath $Runner)) { return $false }
  $safeReason = ($Reason -replace '[^A-Za-z0-9._-]','_')
  if ($safeReason.Length -gt 80) { $safeReason = $safeReason.Substring(0,80) }
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $launchLog = Join-Path $BaseDir ("ttittulares-image-launch-" + $stamp + "-" + $safeReason + ".log")
  $launchErr = Join-Path $BaseDir ("ttittulares-image-launch-" + $stamp + "-" + $safeReason + ".err.log")
  $old = $env:TT_CHAT_MESSAGE_B64
  $proc = $null
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { throw "Node no disponible" }
    $proc = Start-Process -FilePath $node.Source -ArgumentList @($Runner,"titulares","--enviar") -WindowStyle Hidden -PassThru -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr
    if (-not $proc) { throw "Start-Process no devolvió proceso" }
    Write-Log "IMAGE CHAT PROCESS STARTED pid=$($proc.Id) marker=$ExpectedMarker"
  } catch {
    Write-Log "IMAGE CHAT START ERROR :: $Reason :: $($_.Exception.Message)"
    return $false
  } finally {
    if ($null -eq $old) { Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue }
    else { $env:TT_CHAT_MESSAGE_B64 = $old }
  }

  $deadline = (Get-Date).AddSeconds($LaunchConfirmSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $stdout="";$stderr=""
    try { if(Test-Path $launchLog){$stdout=Get-Content $launchLog -Raw -ErrorAction SilentlyContinue} } catch {}
    try { if(Test-Path $launchErr){$stderr=Get-Content $launchErr -Raw -ErrorAction SilentlyContinue} } catch {}
    $joined=[string]$stdout+[Environment]::NewLine+[string]$stderr
    if($joined -match "MODO:\s*PRUEBA"){Write-Log "IMAGE CHAT MODE ERROR :: $Reason";return $false}
    $real=$joined -match "MODO:\s*ENVIO REAL"
    $sent=$joined -match "MENSAJE ENVIADO"
    $launched=$joined -match "EJECUCION LANZADA"
    $generating=$joined -match '"generando"\s*:\s*true'
    if($real -and ($sent -or $launched -or $generating)){
      $why=if($generating){"generando:true"}elseif($launched){"EJECUCION LANZADA"}else{"MENSAJE ENVIADO"}
      Write-Log "IMAGE CHAT CONFIRMED marker=$ExpectedMarker via=$why"
      return $true
    }
    if($joined -match "ERROR:|ERROR ::|Timeout CDP|ChatGPT no confirmó"){Write-Log "IMAGE CHAT LOG ERROR :: $Reason";return $false}
    try{
      $proc.Refresh()
      if($proc.HasExited -and -not $sent -and -not $launched -and -not $generating){Write-Log "IMAGE CHAT PROCESS EXITED :: $Reason";return $false}
    }catch{}
  }
  Write-Log "IMAGE CHAT TIMEOUT :: $Reason"
  return $false
}

function Is-TerminalImageStatus([string]$Status) {
  return @("DONE","ERROR","CANCELLED","SUPERSEDED") -contains ([string]$Status).ToUpperInvariant()
}
function Seen-ImageCommand($State,[string]$CommandId) {
  return @($State.image_commands) -contains $CommandId
}
function Mark-ImageCommand($State,[string]$CommandId,[bool]$Active) {
  $State.image_commands = @((@($State.image_commands) + $CommandId) | Select-Object -Unique | Select-Object -Last 120)
  if ($Active) { $State.active_image_commands = @((@($State.active_image_commands) + $CommandId) | Select-Object -Unique) }
}
function Refresh-ActiveImages($State,$Index) {
  $active=@();$jobs=@()
  if($Index -and $Index.jobs){$jobs=@($Index.jobs)}
  foreach($cmd in @($State.active_image_commands)){
    $job=$jobs|Where-Object{[string]$_.command_id -eq [string]$cmd}|Select-Object -Last 1
    if(-not $job){continue}
    $statusDoc=Read-ImageJob ([string]$job.target_id)
    if(-not $statusDoc){$active += [string]$cmd;continue}
    if(Is-TerminalImageStatus ([string]$statusDoc.status)){Write-Log "IMAGE TERMINAL command=$cmd target=$($job.target_id) status=$($statusDoc.status)";continue}
    try {
      $atText=if($statusDoc.updated_at){[string]$statusDoc.updated_at}else{[string]$statusDoc.requested_at}
      $at=[DateTimeOffset]::Parse($atText)
      if(([DateTimeOffset]::UtcNow-$at).TotalMinutes -gt $ImageStaleMinutes){Write-Log "IMAGE STALE command=$cmd";continue}
    } catch {}
    $active += [string]$cmd
  }
  $State.active_image_commands=@($active|Select-Object -Unique)
}
function Build-ImageMessage($Job) {
  $targetId=[string]$Job.target_id
  $targetName=[string]$Job.target_name
  $commandId=[string]$Job.command_id
  $tweetText=""
  $remate=""
  $factualSummary=""
  $imageStyle="Más gag, menos barroquismo. Una sola idea visual fuerte, composición limpia, pocos elementos protagonistas y acabado cuidado sin recargar."

  try {
    if ($Job.context_snapshot) {
      $tweetText=[string]$Job.context_snapshot.tweet_text
      $remate=[string]$Job.context_snapshot.remate
      $factualSummary=[string]$Job.context_snapshot.factual_summary
      if (-not [string]::IsNullOrWhiteSpace([string]$Job.context_snapshot.image_style)) {
        $imageStyle=[string]$Job.context_snapshot.image_style
      }
    }
  } catch {}

  if ([string]::IsNullOrWhiteSpace($tweetText) -or [string]::IsNullOrWhiteSpace($remate)) {
    Write-Log "IMAGE CONTEXT MISSING target=$targetId command=$commandId"
    return ""
  }

  return @"
TTITTULARES_IMAGE_JOB_V4 $commandId $targetId | Usa ImageGen AHORA y genera UNA SOLA imagen GAG IA para '$targetName'.

TEXTO EXACTO DE LA NOTICIA YA LISTA (NO LO REESCRIBAS):
$tweetText

REMATE EXACTO:
$remate

CONTEXTO FACTUAL COMPLEMENTARIO:
$factualSummary

DIRECCIÓN VISUAL ASIGNADA:
$imageStyle

CONSTRUCCIÓN OBLIGATORIA:
1. Decide internamente UN solo gag central derivado del hecho y del remate.
2. Haz que se entienda en 1-2 segundos con pocos elementos protagonistas.
3. Acabado cuidado, expresivo y bien dibujado, pero sin barroquismo ni acumulación decorativa.
4. Elimina cualquier objeto, cartel, símbolo o personaje que no refuerce directamente ese único chiste.
5. No te limites a ilustrar literalmente la noticia.

REGLAS:
- No inventes hechos externos.
- No hagas una infografía, interfaz, diagrama, collage ni captura de pantalla.
- No escribas el tuit dentro de la imagen.
- No proceses otra noticia.
- Genera exactamente UNA imagen.
- No persistas la imagen: el puente local recoge el raster.
"@
}

function Test-CustomChatMessageSupport {
  if (-not (Test-Path -LiteralPath $Runner)) {
    Write-Log "CUSTOM MESSAGE UNAVAILABLE: no existe $Runner"
    return $false
  }

  try {
    $text = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
    $ok =
      $text.Contains("TT_CHAT_MESSAGE_B64") -and
      $text.Contains('const enviar = process.argv.includes("--enviar");')

    if (-not $ok) {
      Write-Log "CUSTOM MESSAGE UNAVAILABLE: Ejecutar.js no acepta TT_CHAT_MESSAGE_B64; no se modifica"
      return $false
    }

    Write-Log "CUSTOM MESSAGE READY: validación de solo lectura; Ejecutar.js no modificado"
    return $true
  } catch {
    Write-Log "CUSTOM MESSAGE CHECK ERROR :: $($_.Exception.Message)"
    return $false
  }
}

function Send-Ack([string]$CommandId,[string]$Stage,[string]$Detail = "") {
  $script:LastAckConflict = $null
  try {
    $payload = @{
      task = "pc_ack"
      command_id = $CommandId
      stage = $Stage
      worker_id = $WorkerId
      detail = $Detail
    } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method Post -Uri $RunUrl -ContentType "application/json" -Body $payload -TimeoutSec 12
    Write-Log "ACK $Stage command=$CommandId worker=$WorkerId"
    return "OK"
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    if ($code -eq 409) {
      $body = ""
      $reason = ""
      try {
        $resp = $_.Exception.Response
        if ($resp) {
          $stream = $resp.GetResponseStream()
          if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
          }
        }
      } catch {}
      try {
        if ($body) {
          $parsed = $body | ConvertFrom-Json
          $reason = [string]$parsed.error
        }
      } catch {}
      $script:LastAckConflict = [pscustomobject]@{ reason=$reason; body=$body }
      Write-Log "ACK CONFLICT $Stage command=$CommandId reason=$reason"
      return "CONFLICT"
    }
    Write-Log "ACK ERROR $Stage command=$CommandId :: $($_.Exception.Message)"
    return "ERROR"
  }
}

function Read-NewLauncherText([long]$Offset) {
  if (-not (Test-Path -LiteralPath $LauncherLogPath)) { return "" }
  try {
    $fs = [System.IO.File]::Open($LauncherLogPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
      if ($Offset -gt $fs.Length) { $Offset = 0 }
      [void]$fs.Seek($Offset,[System.IO.SeekOrigin]::Begin)
      $sr = New-Object System.IO.StreamReader($fs,[System.Text.Encoding]::UTF8,$true,4096,$true)
      try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
  } catch { return "" }
}

function Build-EditorialMessage([string]$CommandId) {
  return "TTITTULARES_EDITORIAL_JOB_V2 $CommandId | Ejecuta AHORA la pasada editorial OFICIAL de TTiTTulares. Lee primero ttittulares/editorial-run-prompt.md y el estado autoritativo de ttittulares/editorial-queue.json, ttittulares/status.json y telegram/editorial-processing.json. Procesa TODOS los PROCESSING activos y las reelaboraciones rewrite_pending vigentes. Para cada noticia publicable, cierra texto factual + UN remate y materialízala en Listas/READY; texto+remate bastan para READY y el tuit completo debe quedar <=256 caracteres. Intenta dejar imagen de archivo si la obtienes, pero no bloquees READY por ninguna imagen. NO llames directamente a ImageGen en esta conversación: tras READY, el reparador automático de Listas generará/regenerará la IA, completará el archivo si falta y Telegram entregará el paquete solo cuando la IA sea válida. Relee estado antes de declarar cola vacía. Solo puedes cerrar 0/0 si no queda ningún PROCESSING activo ni rewrite_pending."
}

function Launch-TTiTTulares([string]$CommandId) {
  if (-not (Test-Path -LiteralPath $Runner)) {
    $detail = "No existe $Runner"
    Write-Log "EDITORIAL PROCESS ERROR command=$CommandId :: $detail"
    [void](Send-Ack $CommandId "failed" $detail)
    return $false
  }
  $safeCommandId = ($CommandId -replace '[^A-Za-z0-9._-]','_')
  $launchLog = Join-Path $BaseDir ("ttittulares-launch-" + $safeCommandId + ".log")
  $launchErr = Join-Path $BaseDir ("ttittulares-launch-" + $safeCommandId + ".err.log")
  Remove-Item -LiteralPath $launchLog,$launchErr -Force -ErrorAction SilentlyContinue

  # Editorial: mensaje explícito y auditable, igual que los jobs de imagen.
  $old = $env:TT_CHAT_MESSAGE_B64
  $proc = $null
  $editorialMessage = Build-EditorialMessage $CommandId
  $editorialMarker = "TTITTULARES_EDITORIAL_JOB_V2 $CommandId"
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($editorialMessage)
    $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { throw "Node no disponible para lanzar TTiTTulares" }

    $proc = Start-Process -FilePath $node.Source -ArgumentList @($Runner,"titulares","--enviar") -WindowStyle Hidden -PassThru -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr
    if (-not $proc) { throw "Start-Process no devolvió proceso" }
    Write-Log "EDITORIAL PROCESS STARTED direct-node-real-explicit-message pid=$($proc.Id) command=$CommandId marker=$editorialMarker stdout=$launchLog stderr=$launchErr"
  } catch {
    $detail = "No se pudo lanzar Ejecutar.js titulares --enviar: $($_.Exception.Message)"
    Write-Log "EDITORIAL PROCESS ERROR command=$CommandId :: $detail"
    [void](Send-Ack $CommandId "failed" $detail)
    return $false
  } finally {
    if ($null -eq $old) { Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue }
    else { $env:TT_CHAT_MESSAGE_B64 = $old }
  }

  $deadline = (Get-Date).AddSeconds($LaunchConfirmSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500

    $stdout = ""
    $stderr = ""
    try { if (Test-Path -LiteralPath $launchLog) { $stdout = Get-Content -LiteralPath $launchLog -Raw -ErrorAction SilentlyContinue } } catch {}
    try { if (Test-Path -LiteralPath $launchErr) { $stderr = Get-Content -LiteralPath $launchErr -Raw -ErrorAction SilentlyContinue } } catch {}
    $newText = [string]$stdout + "`n" + [string]$stderr

    if ($newText -match "MODO:\s*PRUEBA") {
      $detail = "Ejecutar.js titulares arrancó en MODO PRUEBA pese a recibir --enviar"
      Write-Log "CHAT LAUNCH MODE ERROR command=$CommandId :: $detail"
      [void](Send-Ack $CommandId "failed" $detail)
      return $false
    }

    $realMode = $newText -match "MODO:\s*ENVIO REAL"
    $responseStarted = $newText -match '"generando"\s*:\s*true'
    $messageSent = $newText -match "MENSAJE ENVIADO"
    $executionLaunched = $newText -match "EJECUCION LANZADA"

    if ($realMode -and ($messageSent -or $executionLaunched -or $responseStarted)) {
      $why = if ($responseStarted) { "generando:true" } elseif ($executionLaunched) { "EJECUCION LANZADA" } else { "MENSAJE ENVIADO" }
      Write-Log "CHAT MESSAGE CONFIRMED command=$CommandId marker=$editorialMarker via=direct-node-real-explicit/$why"
      $launched = Send-Ack $CommandId "launched"
      if ($launched -ne "OK") { Write-Log "LAUNCHED ACK WARNING command=$CommandId result=$launched" }
      return $true
    }

    if ($newText -match "ERROR:|ERROR ::|Timeout CDP|ChatGPT no confirmó") {
      $detail = (($stderr + " " + $stdout) -replace '\s+',' ').Trim()
      if ($detail.Length -gt 700) { $detail = $detail.Substring([Math]::Max(0,$detail.Length-700)) }
      if (-not $detail) { $detail = "Ejecutar.js informó un error al lanzar el chat" }
      Write-Log "CHAT LAUNCH LOG ERROR command=$CommandId :: $detail"
      [void](Send-Ack $CommandId "failed" $detail)
      return $false
    }

    try {
      $proc.Refresh()
      if ($proc.HasExited -and -not $messageSent -and -not $executionLaunched -and -not $responseStarted) {
        $detail = (($stderr + " " + $stdout) -replace '\s+',' ').Trim()
        if (-not $detail) { $detail = "Ejecutar.js terminó sin confirmar el envío. ExitCode=$($proc.ExitCode)" }
        if ($detail.Length -gt 700) { $detail = $detail.Substring([Math]::Max(0,$detail.Length-700)) }
        Write-Log "CHAT PROCESS EXITED command=$CommandId :: $detail"
        [void](Send-Ack $CommandId "failed" $detail)
        return $false
      }
    } catch {}
  }

  $detail = "Ejecutar.js titulares --enviar no confirmó el mensaje editorial explícito en $($LaunchConfirmSeconds)s. Log: $launchLog"
  Write-Log "CHAT MESSAGE TIMEOUT command=$CommandId stdout=$launchLog stderr=$launchErr"
  [void](Send-Ack $CommandId "failed" $detail)
  return $false
}

Ensure-LocalWatchdog

if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

Write-Log "LISTENER START worker=$WorkerId pid=$PID"
$state = Load-State
Ensure-StateFields $state
Save-State $state
$CustomMessageSupport = Test-CustomChatMessageSupport
if(-not $CustomMessageSupport){
  Write-Log "CUSTOM MESSAGE SUPPORT unavailable; ignored for image queue because fixed-tab bridge is self-sufficient"
}

# Diagnóstico inicial: confirma que el proceso sigue vivo y que ve el trigger remoto.
$probe = Read-Trigger
if ($probe -and $probe.command_id) {
  Write-Log "TRIGGER PROBE remote=$($probe.command_id) executor=$($probe.executor) local=$($state.last_command_id)"
} else {
  Write-Log "TRIGGER PROBE FAILED"
}
$script:DirectImageIndexAt=[DateTimeOffset]::MinValue
$imageProbe=Read-ImageIndex
Write-Log "IMAGE PROBE jobs=$(@($imageProbe.jobs).Count) seen=$(@($state.image_commands).Count) active=$(@($state.active_image_commands).Count)"
$loopCount = 0

while ($true) {
  $loopCount++

  try {
    $doc = Read-Trigger
    if ($doc -and $doc.command_id) {
      $commandId = [string]$doc.command_id
      $task = [string]$doc.task
      $executor = [string]$doc.executor
      $project = [string]$doc.project

      if ($commandId -ne [string]$state.last_command_id -and
          $executor -eq "pc_chat_ttittulares_dedicated" -and
          $project -eq "ttittulares" -and
          ($task -eq "editorial" -or -not $task)) {

        # No reproducir al instalar/reiniciar una orden antigua que ya expiró en la app.
        $isFresh = $false
        try {
          $requestedAt = [DateTimeOffset]::Parse([string]$doc.requested_at)
          $ageSeconds = ([DateTimeOffset]::UtcNow - $requestedAt).TotalSeconds
          $isFresh = ($ageSeconds -ge -10 -and $ageSeconds -le $MaxTriggerAgeSeconds)
        } catch {}

        if (-not $isFresh) {
          # Nunca rebobinar last_command_id por una lectura remota antigua.
          # Un snapshot viejo puede reaparecer y provocar que el comando actual
          # se lance de nuevo cuando la lectura fresca vuelva.
          Write-Log "STALE TRIGGER IGNORED command=$commandId requested_at=$($doc.requested_at)"
          $state.conflict_command_id = ""
          $state.conflict_first_at = ""
          Save-State $state
          Start-Sleep -Seconds $PollSeconds
          continue
        }

        $ack = Send-Ack $commandId "picked_up"
        $localFallback = $false
        $remoteAck = $null
        if ($ack -eq "CONFLICT") {
          $remoteAck = Read-AckDirect
          $remoteLaunched = ($remoteAck -and [string]$remoteAck.command_id -eq $commandId -and [string]$remoteAck.stage -eq "launched")
          if ($remoteLaunched) {
            Write-Log "ACK CONFLICT RESOLVED command=$commandId reason=remote-ack-launched worker=$($remoteAck.worker_id)"
            $state.last_command_id = $commandId
            $state.conflict_command_id = ""
            $state.conflict_first_at = ""
            Save-State $state
            $ack = "REMOTE_LAUNCHED"
          } else {
            $reason = ""
            if ($script:LastAckConflict) { $reason = [string]$script:LastAckConflict.reason }
            $remoteMatches = ($remoteAck -and [string]$remoteAck.command_id -eq $commandId)
            $staleBackendConflict = (-not $remoteMatches) -and (Confirm-DirectTriggerCurrent $commandId) -and
              ([string]::IsNullOrWhiteSpace($reason) -or $reason -eq "command_id ya no es el actual")
            if ($staleBackendConflict) {
              # El trigger de GitHub HEAD es autoritativo y el ACK directo demuestra que
              # nadie ha reclamado esta orden. Solo en este caso se permite el bypass.
              $localFallback = $true
              Write-Log "ACK 409 BYPASSED command=$commandId reason=stale-backend-trigger"
            }
          }
        }

        if ($ack -eq "OK" -or $localFallback) {
          try {
            $messageSent = Launch-TTiTTulares $commandId
            if ($messageSent) {
              Write-Log "LAUNCH CONFIRMED command=$commandId via=direct-node"
              # Una orden solo se consume localmente cuando el envío físico al chat
              # quedó confirmado. Un fallo de lanzamiento debe poder reintentarse.
              $state.last_command_id = $commandId
              $state.conflict_command_id = ""
              $state.conflict_first_at = ""
              Save-State $state
            } else {
              Write-Log "LAUNCH FAILED command=$commandId via=direct-node; command remains retryable"
            }
          } catch {
            Write-Log "LAUNCH ERROR command=$commandId :: $($_.Exception.Message)"
          }
        } elseif ($ack -eq "CONFLICT") {
          # Nunca consumir por timeout. Solo un ACK autoritativo en stage=launched
          # permite concluir que otra instancia ya ejecutó la orden.
          if ([string]$state.conflict_command_id -ne $commandId) {
            $state.conflict_command_id = $commandId
            $state.conflict_first_at = [DateTimeOffset]::UtcNow.ToString("o")
            Save-State $state
          } else {
            $remoteAck = Read-AckDirect
            if ($remoteAck -and [string]$remoteAck.command_id -eq $commandId -and [string]$remoteAck.stage -eq "launched") {
              Write-Log "CONFLICT SETTLED command=$commandId reason=remote-ack-launched worker=$($remoteAck.worker_id)"
              $state.last_command_id = $commandId
              $state.conflict_command_id = ""
              $state.conflict_first_at = ""
              Save-State $state
            } else {
              Write-Log "CONFLICT RETAINED command=$commandId; no authoritative launched ACK"
            }
          }
        }
      }
    }
  } catch {
    Write-Log "LOOP ERROR :: $($_.Exception.Message)"
  }

  # 2) Jobs de Gag IA automáticos/manuales posteriores a READY
  try {
    $idx=Read-ImageIndex
    Refresh-ActiveImages $state $idx
    Save-State $state
    $localBridgeBusy=Test-ImageBridgeBusy
    if(-not $localBridgeBusy){
      [void](Recover-ChromeCdpFromRecentImageFailure $state $idx)
      $localBridgeBusy=Test-ImageBridgeBusy
    }
    $slots=if($localBridgeBusy){0}else{[Math]::Max(0,$MaxParallelImageChats-@($state.active_image_commands).Count)}
    if($slots -gt 0){
      $jobs=@();if($idx -and $idx.jobs){$jobs=@($idx.jobs)}
      foreach($job in $jobs){
        if($slots -le 0){break}
        $commandId=[string]$job.command_id
        $targetId=[string]$job.target_id
        if(-not $commandId -or -not $targetId){continue}
        $recent=$true
        try{$requested=[DateTimeOffset]::Parse([string]$job.requested_at);if(([DateTimeOffset]::UtcNow-$requested).TotalHours -gt 12){$recent=$false}}catch{}
        if(-not $recent){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        $statusDoc=Read-ImageJob $targetId
        if(-not $statusDoc -or [string]$statusDoc.command_id -ne $commandId){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        if(Is-TerminalImageStatus ([string]$statusDoc.status)){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        # Un REQUESTED es autoritativamente pendiente aunque un intento anterior
        # de picked_up lo haya dejado por error en image_commands. Esto permite
        # recuperarse de 409/5xx transitorios sin reemitir el job.
        $requestedStatus=([string]$statusDoc.status).ToUpperInvariant() -eq "REQUESTED"
        if((Seen-ImageCommand $state $commandId) -and -not $requestedStatus){continue}
        # PRE-FLIGHT: no consumir el job con Chrome/CDP roto. Un fallo previo de
        # Chrome puede dejar 9223 vivo pero sin una pestaña ChatGPT utilizable.
        # Reparamos antes del picked_up para que el job siga siendo reintentable.
        if(-not (Test-DedicatedChromeCdpHealthy)){
          if(Test-OtherImageBridgeBusy){
            Write-Log "IMAGE CHROME PREFLIGHT WAIT target=$targetId command=$commandId reason=ttendencias-image-active"
            continue
          }
          Write-Log "IMAGE CHROME PREFLIGHT FAILED target=$targetId command=$commandId"
          if(-not (Restart-DedicatedChromeCdp $commandId "preflight-unhealthy")){
            Write-Log "IMAGE CHROME PREFLIGHT RETRY target=$targetId command=$commandId"
            continue
          }
          Start-Sleep -Seconds 2
          if(-not (Test-DedicatedChromeCdpHealthy)){
            Write-Log "IMAGE CHROME PREFLIGHT STILL UNHEALTHY target=$targetId command=$commandId"
            continue
          }
          Write-Log "IMAGE CHROME PREFLIGHT RECOVERED target=$targetId command=$commandId"
          $state.last_chrome_recovery_command_id=$commandId
          $state.last_chrome_recovery_at=[DateTimeOffset]::UtcNow.ToString("o")
          Save-State $state
        }
        $forceChromeRecovery=$false
        try{$forceChromeRecovery=[bool]$statusDoc.force_chrome_recovery}catch{}
        if($forceChromeRecovery){
          if(Test-OtherImageBridgeBusy){
            Write-Log "IMAGE FORCE CHROME RECOVERY WAIT target=$targetId command=$commandId reason=ttendencias-image-active"
            continue
          }
          if(-not (Restart-DedicatedChromeCdp $commandId "force_chrome_recovery")){
            Write-Log "IMAGE FORCE CHROME RECOVERY RETRY target=$targetId command=$commandId"
            continue
          }
          $state.last_chrome_recovery_command_id=$commandId
          $state.last_chrome_recovery_at=[DateTimeOffset]::UtcNow.ToString("o")
          Save-State $state
        }
        Write-Log "IMAGE NEW target=$targetId command=$commandId name=$($job.target_name)"
        $uploadSecret=New-ImageUploadSecret
        $uploadHash=Get-Sha256Hex $uploadSecret
        if(-not (Send-ImageAck $targetId $commandId "picked_up" "" $uploadHash "")){
          # No consumir el command_id por un fallo de transporte/409 transitorio.
          # Si el servidor lo hizo terminal, el siguiente sondeo lo detectará.
          Write-Log "IMAGE PICKUP RETRYABLE target=$targetId command=$commandId"
          continue
        }
        $message=Build-ImageMessage $statusDoc
        if(-not $message){
          $reason="El job de imagen no contiene context_snapshot factual; se cancela para evitar una imagen genérica."
          Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }
        # FASE 1: una única pestaña física de ChatGPT para todos los GAG IA.
        # El bridge conserva el target CDP y crea una conversación nueva dentro
        # de ESA MISMA pestaña por noticia. El listener ya no abre otra pestaña
        # ni intenta relocalizarla con Ejecutar.js.
        if(-not (Start-ImageBridge $commandId $targetId $uploadSecret "[]" "")){
          $reason="No se pudo iniciar el bridge de pestaña fija."
          Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
          Mark-ImageCommand $state $commandId $false;Save-State $state;continue
        }
        Write-Log "IMAGE FIXED TAB BRIDGE STARTED target=$targetId command=$commandId"
        Mark-ImageCommand $state $commandId $true;Save-State $state;$slots--
      }
    }
  } catch {
    Write-Log "IMAGE LOOP ERROR :: $($_.Exception.Message)"
  }

  if (($loopCount % 20) -eq 0) {
    try {
      $hb = Read-Trigger
      if ($hb -and $hb.command_id) {
        $hidx=Read-ImageIndex
        Write-Log "HEARTBEAT remote=$($hb.command_id) executor=$($hb.executor) local=$($state.last_command_id) image_jobs=$(@($hidx.jobs).Count) image_active=$(@($state.active_image_commands).Count)"
      } else {
        Write-Log "HEARTBEAT trigger_unavailable"
      }
    } catch {}
  }
  Start-Sleep -Seconds $PollSeconds
}
