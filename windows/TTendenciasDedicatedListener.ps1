# TTendenciasDedicatedListener.ps1
# official-pipeline-restart-token: 2026-10-06-v16-no-kernel-mutex
# Listener dedicado de TTendencias: editorial + cola automática/manual de imágenes IA por entrada.
# No procesa TTiTTulares.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$ImageBridge = Join-Path $BaseDir "TTendenciasImageBridge.js"
$ImageBridgeLockPath = Join-Path $BaseDir "ttendencias-image-bridge.lock.json"
$OtherImageBridgeLockPath = Join-Path $BaseDir "ttittulares-image-bridge.lock.json"
$StatePath = Join-Path $BaseDir "ttendencias-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttendencias-mobile-trigger.log"
$WatchdogPath = Join-Path $BaseDir "TT-LocalWatchdog.ps1"
$LauncherLogPath = Join-Path $BaseDir "tendencias.log"

# TTendencias uses Cloudflare independently of Vercel. Optional user-scoped rollback override.
$StatusBase = [Environment]::GetEnvironmentVariable("TTENDENCIAS_SERVICE_BASE", "User")
if (-not $StatusBase) { $StatusBase = "https://ttendencias-no-vercel-test.fabricelop.workers.dev" }
$StatusBase = $StatusBase.TrimEnd("/")
$ListenerSnapshotUrl = "$StatusBase/api/ttendencias-run-status?view=listener-snapshot"
$ImageJobUrlBase = "$StatusBase/api/ttendencias-run-status?view=image-job&strong=1&id="
$RunUrl = "$StatusBase/api/ttendencias-run"
$ControlBranch = "control/ttendencias-run-trigger"
$ControlRepoUrl = "https://github.com/fabricelop/europapress-rss.git"
$script:ControlHeadSha = ""
$script:ControlHeadAt = [DateTimeOffset]::MinValue
$script:ControlHeadApiRetryAt = [DateTimeOffset]::MinValue
$DirectTriggerRefreshSeconds = 60
$script:DirectTriggerCache = $null
$script:DirectTriggerAt = [DateTimeOffset]::MinValue
$script:LastAckConflict = $null

$WorkerId = "ttendencias-dedicated-v16"
$PollSeconds = 15
$LaunchConfirmSeconds = 30
$ClaimRetrySeconds = 38
$MaxTriggerAgeSeconds = 86400
$MaxParallelImageChats = 1
$ImageStaleMinutes = 45
$SnapshotStrongSeconds = 30
$SnapshotCacheSeconds = 12
$script:ListenerSnapshotCache = $null
$script:ListenerSnapshotAt = [DateTimeOffset]::MinValue
$script:LastStrongSnapshotAt = [DateTimeOffset]::MinValue
# v16: no usar mutex de kernel. El reparador y TT-LocalWatchdog
# deduplican por CommandLine/PID; un mutex retenido podía impedir arrancar
# antes incluso de escribir el primer log.

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

function Read-JsonUrl([string]$Url, [bool]$Quiet = $false) {
  try {
    return Invoke-RestMethod -Uri (CacheBust $Url) -Headers @{
      "Cache-Control" = "no-cache"
      "User-Agent" = "TTendencias-Dedicated-Listener"
    } -TimeoutSec 12
  } catch {
    if (-not $Quiet) { Write-Log "HTTP ERROR $Url :: $($_.Exception.Message)" }
    return $null
  }
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
      "User-Agent" = "TTendencias-Dedicated-Listener"
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

function Get-ControlHeadSha([switch]$Force) {
  $now=[DateTimeOffset]::UtcNow
  # Los listeners ya comparten una cuota REST anonima de solo 60/h.
  # Resolver primero con git ls-remote evita consumirla mientras git funcione.
  $maxAge=if($Force){15}else{90}
  if($script:ControlHeadSha -and (($now-$script:ControlHeadAt).TotalSeconds -lt $maxAge)){
    return $script:ControlHeadSha
  }
  try{
    $git=Get-Command git.exe -ErrorAction SilentlyContinue
    if(-not $git){$git=Get-Command git -ErrorAction SilentlyContinue}
    if($git){
      $oldPrompt=$env:GIT_TERMINAL_PROMPT
      try{
        $env:GIT_TERMINAL_PROMPT="0"
        $line=& $git.Source ls-remote $ControlRepoUrl ("refs/heads/"+$ControlBranch) 2>$null | Select-Object -First 1
      }finally{
        if($null -eq $oldPrompt){Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue}
        else{$env:GIT_TERMINAL_PROMPT=$oldPrompt}
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
  # REST anonima: solo como ultima alternativa y a lo sumo una vez cada 15 min
  # ante errores. No convertir un 403 en cientos de reintentos por hora.
  if($now -ge $script:ControlHeadApiRetryAt){
    $script:ControlHeadApiRetryAt=$now.AddMinutes(15)
    try{
      $refUrl="https://api.github.com/repos/fabricelop/europapress-rss/git/ref/heads/"+$ControlBranch
      $r=Invoke-RestMethod -Uri (CacheBust $refUrl) -Headers @{
        "Accept"="application/vnd.github+json"
        "User-Agent"="TT-Control-Head-Fallback"
        "Cache-Control"="no-cache"
      } -TimeoutSec 12
      $sha=[string]$r.object.sha
      if($sha -match '^[0-9a-fA-F]{40}$'){
        $script:ControlHeadSha=$sha.ToLowerInvariant()
        $script:ControlHeadAt=$now
        # Incluso si REST funciona, reservar la cuota anonima para otros procesos.
        # Durante este intervalo RAW por rama sigue disponible.
        return $script:ControlHeadSha
      }
    }catch{
      Write-Log "CONTROL HEAD ANON API WARNING :: $($_.Exception.Message)"
    }
  }
  # Nunca fijar para siempre un SHA viejo si todas las fuentes fallan:
  # la ruta RAW de rama con cache-busting es el fallback.
  return ""
}

function Get-ControlRawUrl([string]$Path,[switch]$ForceHead) {
  $sha=Get-ControlHeadSha -Force:$ForceHead
  $ref=if($sha){$sha}else{$ControlBranch}
  return "https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$ref+"/"+$Path.TrimStart("/")
}

function Read-TriggerDirect([switch]$Force) {
  $now=[DateTimeOffset]::UtcNow
  # Cachear incluso fallos para evitar 4 consultas/minuto si hay 403.
  if(-not $Force -and (($now-$script:DirectTriggerAt).TotalSeconds -lt $DirectTriggerRefreshSeconds)){
    return $script:DirectTriggerCache
  }
  try{
    $parsed=Invoke-RestMethod -Uri (CacheBust (Get-ControlRawUrl "trends/run-now-trigger.json" -ForceHead:$Force)) -Headers @{
      "User-Agent"="TTendencias-Dedicated-Listener-DirectTrigger-Raw"
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
  $script:DirectTriggerAt=$now
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
    return Invoke-RestMethod -Uri (CacheBust (Get-ControlRawUrl "trends/run-ack.json" -ForceHead)) -Headers @{
      "User-Agent"="TTendencias-Dedicated-Listener-DirectAck-Raw"
      "Cache-Control"="no-cache, no-store"
      "Pragma"="no-cache"
    } -TimeoutSec 12
  }catch{
    Write-Log "DIRECT ACK RAW ERROR :: $($_.Exception.Message)"
  }
  return $null
}

function Read-ImageIndex {
  $r=Read-ListenerSnapshot
  if($r -and $r.image_index){return $r.image_index}
  return [pscustomobject]@{ jobs = @() }
}

function Read-ImageJob([string]$TargetId) {
  if (-not $TargetId) { return $null }
  try {
    return Invoke-RestMethod -Uri (CacheBust ($ImageJobUrlBase + [uri]::EscapeDataString($TargetId))) -Headers @{
      "Cache-Control" = "no-cache"
      "User-Agent" = "TTendencias-Dedicated-Listener"
    } -TimeoutSec 12
  } catch {
    Write-Log "IMAGE JOB ERROR target=$TargetId :: $($_.Exception.Message)"
    return $null
  }
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
  }
}

function Save-State($State) {
  $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Ensure-StateFields($State) {
  foreach ($n in @("last_command_id","conflict_command_id","conflict_first_at")) {
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

function Send-Ack([string]$CommandId,[string]$Stage) {
  $script:LastAckConflict = $null
  try {
    $payload = @{
      task = "pc_ack"
      command_id = $CommandId
      stage = $Stage
      worker_id = $WorkerId
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $RunUrl -ContentType "application/json" -Body $payload -TimeoutSec 12 | Out-Null
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

function Send-ImageAck([string]$TargetId,[string]$CommandId,[string]$Stage,[string]$Reason = "",[string]$UploadSecretHash = "",[string]$UploadSecret = "",[string]$DiagnosticTargetId = "") {
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
    if ($DiagnosticTargetId) { $body.diagnostic_target_id = $DiagnosticTargetId }
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
    $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/windows/TTendenciasImageBridge.js?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $doc = Invoke-RestMethod -Uri $api -Headers @{
      "Accept" = "application/vnd.github+json"
      "User-Agent" = "TTendencias-image-bridge-refresh"
      "Cache-Control" = "no-cache"
    } -TimeoutSec 15
    if (-not $doc.content) { throw "GitHub API sin contenido" }
    $raw = [Convert]::FromBase64String(([string]$doc.content -replace "\s",""))
    [IO.File]::WriteAllBytes($tmp,$raw)

    $txt = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    foreach ($needle in @(
      'BRIDGE_MODE="capture-only-v28-dead-submit-retry"',
      'view=image-job&strong=1&id=',
      'imagesAfterMarker',
      'BRIDGE SUBMIT VERIFY WARNING'
    )) {
      if (-not $txt.Contains($needle)) { throw "Bridge remoto sin garantía: $needle" }
    }
    & $NodePath --check $tmp *> $null
    if ($LASTEXITCODE -ne 0) { throw "node --check falló en bridge remoto" }

    Move-Item -LiteralPath $tmp -Destination $ImageBridge -Force
    Write-Log "IMAGE BRIDGE REFRESHED source=github-api sha=$($doc.sha)"
    return $true
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Log "IMAGE BRIDGE REFRESH WARNING :: $($_.Exception.Message)"
  }

  if (Test-Path -LiteralPath $ImageBridge) {
    try {
      $txt = Get-Content -LiteralPath $ImageBridge -Raw -Encoding UTF8
      if ($txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"') -and $txt.Contains('view=image-job&strong=1&id=') -and $txt.Contains('BRIDGE SUBMIT VERIFY WARNING')) {
        & $NodePath --check $ImageBridge *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Log "IMAGE BRIDGE USING VALID LOCAL FALLBACK version=v28"
          return $true
        }
      }
    } catch {}
  }

  Write-Log "IMAGE BRIDGE ERROR no hay bridge v28 válido; no se lanza imagen con código antiguo"
  return $false
}

function Test-ImageBridgeBusy {
  if (-not (Test-Path -LiteralPath $ImageBridgeLockPath)) { return $false }
  try {
    $lock = Get-Content -LiteralPath $ImageBridgeLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pidValue = [int]$lock.pid
    if ($pidValue -gt 0) {
      $p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
      if ($p) {
        Write-Log "IMAGE LOCAL LOCK ACTIVE pid=$pidValue command=$($lock.command_id) target=$($lock.target_id)"
        return $true
      }
    }
  } catch {}
  Remove-Item -LiteralPath $ImageBridgeLockPath -Force -ErrorAction SilentlyContinue
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
    return ""
  } catch {
    Write-Log "IMAGE TARGET HANDOFF ERROR command=$CommandId :: $($_.Exception.Message)"
    return ""
  }
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
        $isOtherBridge=($proc -and [string]$proc.CommandLine -like "*TTiTTularesImageBridge.js*")
      }catch{}
      if($isOtherBridge){
        Write-Log "IMAGE OTHER LOCK STALE project=ttittulares pid=$pidValue command=$([string]$lock.command_id) target=$([string]$lock.target_id) age_gt_12m=1"
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
  } catch { return $false }
}

function Restart-DedicatedChromeCdp([string]$CommandId,[string]$Reason) {
  if(Test-OtherImageBridgeBusy){
    Write-Log "CHROME CDP RECOVERY DEFERRED command=$CommandId reason=ttittulares-image-active"
    return $false
  }
  Write-Log "CHROME CDP RECOVERY START command=$CommandId reason=$Reason"
  try {
    $roots=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.Name -ieq "chrome.exe" -or $_.Name -ieq "msedge.exe") -and
      [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
    })
    foreach($p in $roots){ try{& taskkill.exe /PID $p.ProcessId /T /F 1>$null 2>$null}catch{} }
    Start-Sleep -Seconds 2
    & schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
    $deadline=(Get-Date).AddSeconds(25)
    while((Get-Date) -lt $deadline){
      if(Test-DedicatedChromeCdpHealthy){
        Write-Log "CHROME CDP RECOVERY OK command=$CommandId killed=$($roots.Count)"
        return $true
      }
      Start-Sleep -Seconds 1
    }
    Write-Log "CHROME CDP RECOVERY FAILED command=$CommandId reason=endpoint-or-chat-not-ready"
  } catch {
    Write-Log "CHROME CDP RECOVERY ERROR command=$CommandId :: $($_.Exception.Message)"
  }
  return $false
}

function Start-ImageBridge([string]$CommandId,[string]$TargetId,[string]$UploadSecret,[string]$TargetSnapshot = "[]",[string]$TargetHintPath = "") {
  if (-not (Test-Path -LiteralPath $ImageBridge)) {
    Write-Log "IMAGE BRIDGE ERROR missing=$ImageBridge"
    return $false
  }
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) {
    Write-Log "IMAGE BRIDGE ERROR node no encontrado"
    return $false
  }
  if (-not (Ensure-ImageBridgeLatest $node.Source)) {
    return $false
  }
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $out = Join-Path $BaseDir ("ttendencias-image-bridge-" + $stamp + "-" + $TargetId + ".log")
  $err = Join-Path $BaseDir ("ttendencias-image-bridge-" + $stamp + "-" + $TargetId + ".err.log")
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

function Launch-EditorialProcess([string]$CommandId) {
  if (-not (Test-Path -LiteralPath $Launcher)) { throw "No existe $Launcher" }

  try {
    $p = Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,"tendencias") -WindowStyle Hidden -PassThru
    if (-not $p) { throw "Start-Process no devolvió proceso" }
    Write-Log "EDITORIAL PROCESS STARTED pid=$($p.Id) command=$CommandId"
    return $true
  } catch {
    Write-Log "EDITORIAL PROCESS ERROR command=$CommandId :: $($_.Exception.Message)"
    return $false
  }
}

function Launch-ProjectChat([string]$Reason,[string]$Message = "",[string]$ExpectedMarker = "") {
  if (-not (Test-Path -LiteralPath $Runner)) { throw "No existe $Runner" }
  $safeReason = ($Reason -replace '[^A-Za-z0-9._-]','_')
  if ($safeReason.Length -gt 80) { $safeReason = $safeReason.Substring(0,80) }
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $launchLog = Join-Path $BaseDir ("ttendencias-launch-" + $stamp + "-" + $safeReason + ".log")
  $launchErr = Join-Path $BaseDir ("ttendencias-launch-" + $stamp + "-" + $safeReason + ".err.log")
  Remove-Item -LiteralPath $launchLog,$launchErr -Force -ErrorAction SilentlyContinue

  $old = $env:TT_CHAT_MESSAGE_B64
  $proc = $null
  try {
    if ($Message) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
      $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)
    } else {
      Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue
    }

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { throw "Node no disponible para lanzar TTendencias" }

    $proc = Start-Process -FilePath $node.Source -ArgumentList @($Runner,"tendencias","--enviar") -WindowStyle Hidden -PassThru -RedirectStandardOutput $launchLog -RedirectStandardError $launchErr
    if (-not $proc) { throw "Start-Process no devolvió proceso" }
    Write-Log "PROCESS STARTED direct-node-real pid=$($proc.Id) :: $Reason marker=$ExpectedMarker stdout=$launchLog stderr=$launchErr"
  } catch {
    Write-Log "PROCESS START ERROR :: $Reason :: $($_.Exception.Message)"
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
    $joined = [string]$stdout + "`n" + [string]$stderr

    # El stdout/stderr es exclusivo de ESTE proceso. No exigimos que Ejecutar.js
    # reimprima el mensaje completo: TT_CHAT_MESSAGE_B64 ya fue heredado por este proceso.
    # El marcador se conserva solo para diagnóstico.
    if ($joined -match "MODO:\s*PRUEBA") {
      Write-Log "CHAT LAUNCH MODE ERROR :: $Reason :: Ejecutar.js arrancó en MODO PRUEBA"
      return $false
    }

    $realMode = $joined -match "MODO:\s*ENVIO REAL"
    $responseStarted = $joined -match '"generando"\s*:\s*true'
    $messageSent = $joined -match "MENSAJE ENVIADO"
    $executionLaunched = $joined -match "EJECUCION LANZADA"

    if ($realMode -and ($messageSent -or $executionLaunched -or $responseStarted)) {
      $why = if ($responseStarted) { "generando:true" } elseif ($executionLaunched) { "EJECUCION LANZADA" } else { "MENSAJE ENVIADO" }
      Write-Log "CHAT MESSAGE CONFIRMED :: $Reason marker=$ExpectedMarker via=$why"
      return $true
    }

    if ($joined -match "ERROR:|ERROR ::|Timeout CDP|ChatGPT no confirmó") {
      $detail = (($stderr + " " + $stdout) -replace '\s+',' ').Trim()
      if ($detail.Length -gt 700) { $detail = $detail.Substring([Math]::Max(0,$detail.Length-700)) }
      Write-Log "CHAT LAUNCH LOG ERROR :: $Reason :: $detail"
      return $false
    }

    try {
      $proc.Refresh()
      if ($proc.HasExited -and -not $messageSent -and -not $executionLaunched -and -not $responseStarted) {
        $detail = (($stderr + " " + $stdout) -replace '\s+',' ').Trim()
        if (-not $detail) { $detail = "Ejecutar.js terminó sin confirmar el envío. ExitCode=$($proc.ExitCode)" }
        if ($detail.Length -gt 700) { $detail = $detail.Substring([Math]::Max(0,$detail.Length-700)) }
        Write-Log "CHAT PROCESS EXITED :: $Reason :: $detail"
        return $false
      }
    } catch {}
  }

  Write-Log "CHAT MESSAGE TIMEOUT :: $Reason marker=$ExpectedMarker after=$($LaunchConfirmSeconds)s stdout=$launchLog stderr=$launchErr"
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
  if ($Active) {
    $State.active_image_commands = @((@($State.active_image_commands) + $CommandId) | Select-Object -Unique)
  }
}

function Refresh-ActiveImages($State,$Index) {
  $active = @()
  $jobs = @()
  if ($Index -and $Index.jobs) { $jobs = @($Index.jobs) }

  foreach ($cmd in @($State.active_image_commands)) {
    $job = $jobs | Where-Object { [string]$_.command_id -eq [string]$cmd } | Select-Object -Last 1
    if (-not $job) { continue }

    $statusDoc = Read-ImageJob ([string]$job.target_id)
    if (-not $statusDoc) { $active += [string]$cmd; continue }

    $status = [string]$statusDoc.status
    if (Is-TerminalImageStatus $status) {
      Write-Log "IMAGE TERMINAL command=$cmd target=$($job.target_id) status=$status"
      continue
    }

    try {
      $atText = if ($statusDoc.updated_at) { [string]$statusDoc.updated_at } else { [string]$statusDoc.requested_at }
      $at = [DateTimeOffset]::Parse($atText)
      if (([DateTimeOffset]::UtcNow - $at).TotalMinutes -gt $ImageStaleMinutes) {
        Write-Log "IMAGE STALE command=$cmd target=$($job.target_id) status=$status"
        continue
      }
    } catch {}

    $active += [string]$cmd
  }

  $State.active_image_commands = @($active | Select-Object -Unique)
}

function Build-EditorialMessage([string]$CommandId) {
  return "TTENDENCIAS_EDITORIAL_JOB_V2 $CommandId | Ejecuta AHORA la pasada editorial real de TTendencias. Lee primero trends/editorial-run-prompt.md y trends/editorial-queue.json desde main. Antes de declarar cola vacía, relee editorial-queue.json y procesa TODOS los items status preparing/update, del más antiguo al más reciente, validando cada (id,revision) justo antes de tratarlo. NO llames a ImageGen ni generes imágenes en esta pasada. Solo puedes cerrar 0/0 si, tras releer main, no queda ningún preparing/update ni reexplicación pendiente."
}

function Build-ImageMessage($Job) {
  $targetId = [string]$Job.target_id
  $targetName = [string]$Job.target_name
  $commandId = [string]$Job.command_id
  $contextJson = ""

  try {
    if ($Job.context_snapshot) {
      $contextJson = ($Job.context_snapshot | ConvertTo-Json -Depth 10 -Compress)
    }
  } catch {}

  if ([string]::IsNullOrWhiteSpace($contextJson) -or $contextJson -eq "null" -or $contextJson -eq "{}") {
    Write-Log "IMAGE CONTEXT MISSING target=$targetId command=$commandId"
    return ""
  }

  return @"
TTENDENCIAS_IMAGE_JOB_V4 $commandId $targetId | Usa ImageGen AHORA y genera UNA imagen IA para '$targetName'.

CONTEXTO FACTUAL AUTORITATIVO (úsalo DIRECTAMENTE; no necesitas abrir GitHub ni reinvestigar):
$contextJson

Respeta OBLIGATORIAMENTE image_style e image_style_name de context_snapshot. Principio fijo: más gag, menos barroquismo; UNA sola idea visual fuerte, lectura inmediata, pocos elementos protagonistas y acabado cuidado sin recargar. No ilustres literalmente el titular ni mezcles varias metáforas. Una sola escena coherente, sin infografía, collage, interfaz ni captura de pantalla. No inventes hechos externos. No proceses otra entrada ni persistas la imagen: el puente local recoge el raster.
"@
}

Ensure-LocalWatchdog

if (-not (Test-Path -LiteralPath $BaseDir)) {
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}

Write-Log "LISTENER START worker=$WorkerId pid=$PID"
$state = Load-State
Ensure-StateFields $state
Save-State $state

$CustomMessageSupport = Test-CustomChatMessageSupport

$probe = Read-Trigger
if ($probe -and $probe.command_id) {
  Write-Log "TRIGGER PROBE remote=$($probe.command_id) executor=$($probe.executor) local=$($state.last_command_id)"
} else {
  Write-Log "TRIGGER PROBE FAILED"
}

$imageProbe = Read-ImageIndex
$imageCount = @($imageProbe.jobs).Count
Write-Log "IMAGE PROBE jobs=$imageCount seen=$(@($state.image_commands).Count) active=$(@($state.active_image_commands).Count)"

$loopCount = 0

while ($true) {
  $loopCount++

  # 1) Editorial
  try {
    $doc = Read-Trigger
    if ($doc -and $doc.command_id) {
      $commandId = [string]$doc.command_id
      $task = [string]$doc.task
      $executor = [string]$doc.executor
      $project = [string]$doc.project

      if ($commandId -ne [string]$state.last_command_id -and
          $executor -eq "pc_chat_ttendencias_dedicated" -and
          $project -eq "ttendencias" -and
          ($task -eq "editorial" -or -not $task)) {

        $isFresh = $false
        try {
          $requestedAt = [DateTimeOffset]::Parse([string]$doc.requested_at)
          $ageSeconds = ([DateTimeOffset]::UtcNow - $requestedAt).TotalSeconds
          $isFresh = ($ageSeconds -ge -10 -and $ageSeconds -le $MaxTriggerAgeSeconds)
        } catch {}

        if (-not $isFresh) {
          # Nunca rebobinar last_command_id por una lectura remota antigua.
          # Un snapshot viejo puede reaparecer tras procesar el comando actual y,
          # si lo guardamos como local, el mismo comando nuevo se relanza después.
          Write-Log "STALE TRIGGER IGNORED command=$commandId requested_at=$($doc.requested_at)"
          $state.conflict_command_id = ""
          $state.conflict_first_at = ""
          Save-State $state
        } else {
          $ack = Send-Ack $commandId "picked_up"
          $localFallback = $false
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
                $localFallback = $true
                Write-Log "ACK 409 BYPASSED command=$commandId reason=stale-backend-trigger"
              }
            }
          }

          if ($ack -eq "OK" -or $localFallback) {
            try {
              # Editorial usa el mismo lanzador robusto que las imágenes:
              # solo damos ACK launched cuando Ejecutar.js confirma que el mensaje
              # fue enviado o que ChatGPT ya empezó a responder.
              $editorialMessage = Build-EditorialMessage $commandId
              $editorialMarker = "TTENDENCIAS_EDITORIAL_JOB_V2 $commandId"
              $messageSent = Launch-ProjectChat "editorial command=$commandId" $editorialMessage $editorialMarker
              if ($messageSent) {
                $launched = Send-Ack $commandId "launched"
                if ($launched -ne "OK") { Write-Log "LAUNCH ACK WARNING command=$commandId result=$launched" }
                $state.last_command_id = $commandId
                $state.conflict_command_id = ""
                $state.conflict_first_at = ""
                Save-State $state
              } else {
                Write-Log "LAUNCH NOT CONFIRMED command=$commandId; no launched ACK; command remains retryable"
              }
            } catch {
              Write-Log "LAUNCH ERROR command=$commandId :: $($_.Exception.Message)"
            }
          } elseif ($ack -eq "CONFLICT") {
            # Nunca consumir una orden por timeout: solo el ACK directo en launched
            # demuestra que otra instancia la ejecutó.
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
    }
  } catch {
    Write-Log "EDITORIAL LOOP ERROR :: $($_.Exception.Message)"
  }

  # 2) Imágenes independientes
  try {
    $idx = Read-ImageIndex
    Refresh-ActiveImages $state $idx
    Save-State $state

    $localBridgeBusy=Test-ImageBridgeBusy
    $otherBridgeBusy=Test-OtherImageBridgeBusy
    $slots = if($localBridgeBusy -or $otherBridgeBusy){0}else{[Math]::Max(0, $MaxParallelImageChats - @($state.active_image_commands).Count)}
    if($otherBridgeBusy){Write-Log "IMAGE GLOBAL SLOT WAIT project=ttittulares"}

    if ($slots -gt 0 -and $CustomMessageSupport) {
      $jobs = @()
      if ($idx -and $idx.jobs) { $jobs = @($idx.jobs) }

      foreach ($job in $jobs) {
        if ($slots -le 0) { break }

        $commandId = [string]$job.command_id
        $targetId = [string]$job.target_id
        if (-not $commandId -or -not $targetId) { continue }

        # No reproducir trabajos muy antiguos al reinstalar.
        $recent = $true
        try {
          $requested = [DateTimeOffset]::Parse([string]$job.requested_at)
          if (([DateTimeOffset]::UtcNow - $requested).TotalHours -gt 12) { $recent = $false }
        } catch {}
        if (-not $recent) {
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }

        $statusDoc = Read-ImageJob $targetId
        if (-not $statusDoc -or [string]$statusDoc.command_id -ne $commandId) {
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }
        if (Is-TerminalImageStatus ([string]$statusDoc.status)) {
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }

        # Un command_id puede quedar en image_commands aunque el ACK inicial no
        # llegara a accepted (p. ej. backend/cuota/cache temporal). Si el job
        # autoritativo sigue siendo ESTE command_id, continúa REQUESTED/queued y
        # no está activo localmente, debe volver a ser intentable.
        $seenBefore = Seen-ImageCommand $state $commandId
        if ($seenBefore) {
          $locallyActive = @($state.active_image_commands) -contains $commandId
          $remoteStatus = ([string]$statusDoc.status).ToUpperInvariant()
          $remotePhase = ([string]$statusDoc.phase).ToLowerInvariant()
          $retryableSeen = (-not $locallyActive) -and $remoteStatus -eq "REQUESTED" -and
            ([string]::IsNullOrWhiteSpace($remotePhase) -or $remotePhase -eq "queued" -or $remotePhase -eq "requested")
          if (-not $retryableSeen) { continue }
          Write-Log "IMAGE RETRY SEEN target=$targetId command=$commandId status=$remoteStatus phase=$remotePhase"
        }

        # PRE-FLIGHT tras reinicios/OOM de Chrome: no consumir el job hasta
        # tener CDP y una pestaña ChatGPT utilizables.
        if(-not (Test-DedicatedChromeCdpHealthy)){
          if(Test-OtherImageBridgeBusy){
            Write-Log "IMAGE CHROME PREFLIGHT WAIT target=$targetId command=$commandId reason=ttittulares-image-active"
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
        }

        Write-Log "IMAGE NEW target=$targetId command=$commandId name=$($job.target_name)"

        $uploadSecret = New-ImageUploadSecret
        $uploadHash = Get-Sha256Hex $uploadSecret
        if (-not (Send-ImageAck $targetId $commandId "picked_up" "" $uploadHash "")) {
          # El servidor ya movió o rechazó el trabajo. No relanzar el mismo
          # command_id en cada sondeo; una nueva petición tendrá otro id.
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }

        $message = Build-ImageMessage $statusDoc
        if (-not $message) {
          $reason = "El job de imagen no contiene context_snapshot factual; se cancela para evitar una imagen genérica."
          Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }
        $marker = "TTENDENCIAS_IMAGE_JOB_V4 $commandId"
        $targetSnapshot=Get-ChatTargetSnapshot
        $hintSafe=($commandId -replace '[^A-Za-z0-9._-]','_')
        $targetHintPath=Join-Path $BaseDir ("tt-image-target-" + $hintSafe + ".json")
        Remove-Item -LiteralPath $targetHintPath -Force -ErrorAction SilentlyContinue

        # Arrancar el bridge ANTES del envío: así toma una línea base real de
        # tabs/rasteres y puede detectar el cambio aunque ChatGPT reutilice el
        # mismo target y la imagen aparezca muy rápido.
        if (-not (Start-ImageBridge $commandId $targetId $uploadSecret $targetSnapshot $targetHintPath)) {
          $reason = "No se pudo iniciar el puente local de raster antes del lanzamiento."
          Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }
        Start-Sleep -Milliseconds 900

        $sent = Launch-ProjectChat "image command=$commandId target=$targetId" $message $marker
        $handoffId=Publish-ImageTargetHint $targetSnapshot $targetHintPath $commandId
        if($handoffId){ Send-ImageAck $targetId $commandId "target_handoff" "Target exacto de ChatGPT entregado al bridge." "" $uploadSecret $handoffId | Out-Null }
        Send-ImageAck $targetId $commandId "launched" | Out-Null

        if (-not $sent) {
          # El bridge ya estaba observando antes del envío y es la autoridad real:
          # si el mensaje sí llegó, detectará el nuevo raster; si no, cerrará ERROR.
          $reason = "Ejecutar.js no confirmó el envío en $($LaunchConfirmSeconds) s.; bridge pre-lanzamiento verificando."
          Write-Log "IMAGE CHAT UNCONFIRMED; PRELAUNCH BRIDGE VERIFY target=$targetId command=$commandId :: $reason"
        }

        Mark-ImageCommand $state $commandId $true
        Save-State $state
        $slots--
      }
    } elseif ($slots -gt 0 -and -not $CustomMessageSupport) {
      Write-Log "IMAGE QUEUE WAITING: custom message support unavailable"
    }
  } catch {
    Write-Log "IMAGE LOOP ERROR :: $($_.Exception.Message)"
  }

  if (($loopCount % 12) -eq 0) {
    try {
      $hb = Read-Trigger
      $idx = Read-ImageIndex
      Write-Log "HEARTBEAT editorial_remote=$($hb.command_id) editorial_local=$($state.last_command_id) image_jobs=$(@($idx.jobs).Count) image_active=$(@($state.active_image_commands).Count)"
    } catch {}
  }

  Start-Sleep -Seconds $PollSeconds
}
