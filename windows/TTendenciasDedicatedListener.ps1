# TTendenciasDedicatedListener.ps1
# Listener dedicado de TTendencias: ejecuciones editoriales + imágenes IA por entrada.
# No procesa TTiTTulares.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$ImageBridge = Join-Path $BaseDir "TTendenciasImageBridge.js"
$StatePath = Join-Path $BaseDir "ttendencias-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttendencias-mobile-trigger.log"
$LauncherLogPath = Join-Path $BaseDir "tendencias.log"

$StatusBase = "https://europapress-rss.vercel.app"
$ListenerSnapshotUrl = "$StatusBase/api/ttendencias-run-status?view=listener-snapshot"
$ImageJobUrlBase = "$StatusBase/api/ttendencias-run-status?view=image-job&strong=1&id="
$RunUrl = "$StatusBase/api/ttendencias-run"

$WorkerId = "ttendencias-dedicated-v13"
$PollSeconds = 15
$LaunchConfirmSeconds = 30
$ClaimRetrySeconds = 38
$MaxTriggerAgeSeconds = 90
$MaxParallelImageChats = 1
$ImageStaleMinutes = 45
$SnapshotStrongSeconds = 30
$SnapshotCacheSeconds = 12
$script:ListenerSnapshotCache = $null
$script:ListenerSnapshotAt = [DateTimeOffset]::MinValue
$script:LastStrongSnapshotAt = [DateTimeOffset]::MinValue

function Write-Log([string]$Text) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
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

function Read-Trigger {
  $r=Read-ListenerSnapshot
  if($r -and $r.trigger){return $r.trigger}
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
      Write-Log "ACK CONFLICT $Stage command=$CommandId"
      return "CONFLICT"
    }
    Write-Log "ACK ERROR $Stage command=$CommandId :: $($_.Exception.Message)"
    return "ERROR"
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
      'BRIDGE_MODE="capture-only',
      'view=image-job&strong=1&id=',
      'imagesAfterMarker'
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
      if ($txt.Contains('BRIDGE_MODE="capture-only') -and $txt.Contains('view=image-job&strong=1&id=')) {
        & $NodePath --check $ImageBridge *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Log "IMAGE BRIDGE USING VALID LOCAL FALLBACK"
          return $true
        }
      }
    } catch {}
  }

  Write-Log "IMAGE BRIDGE ERROR no hay bridge capture-only válido"
  return $false
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

function Start-ImageBridge([string]$CommandId,[string]$TargetId,[string]$UploadSecret,[string]$TargetSnapshot = "[]") {
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
  try {
    $env:TT_IMAGE_UPLOAD_SECRET = $UploadSecret
    $env:TT_IMAGE_PRELAUNCH_TARGETS_JSON = $(if([string]::IsNullOrWhiteSpace($TargetSnapshot)){"[]"}else{$TargetSnapshot})
    $p = Start-Process -FilePath $node.Source -ArgumentList @($ImageBridge,$CommandId,$TargetId) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p) { throw "Start-Process no devolvió proceso" }
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
TT_IMAGE_JOB_V3 $commandId $targetId | Usa ImageGen AHORA y genera UNA imagen IA para '$targetName'.

CONTEXTO FACTUAL AUTORITATIVO (úsalo DIRECTAMENTE; no necesitas abrir GitHub ni reinvestigar):
$contextJson

Genera un gag visual cómico, satírico, irónico y exagerado basado ESPECÍFICAMENTE en los hechos de ese contexto y en su remate. Evita una ilustración literal y evita por completo una caricatura genérica del país, persona, equipo o nombre de la tendencia. La idea visual debe depender de al menos un hecho concreto del contexto; si no puedes identificarlo, no inventes otro hecho. No proceses otra entrada ni persistas la imagen: el puente local recoge el raster.
"@
}

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
          if ($ack -eq "OK") {
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
              } else {
                Write-Log "LAUNCH NOT CONFIRMED command=$commandId; no launched ACK"
              }
              $state.last_command_id = $commandId
              $state.conflict_command_id = ""
              $state.conflict_first_at = ""
              Save-State $state
            } catch {
              Write-Log "LAUNCH ERROR command=$commandId :: $($_.Exception.Message)"
            }
          } elseif ($ack -eq "CONFLICT") {
            if ([string]$state.conflict_command_id -ne $commandId) {
              $state.conflict_command_id = $commandId
              $state.conflict_first_at = [DateTimeOffset]::UtcNow.ToString("o")
              Save-State $state
            } else {
              try {
                $first = [DateTimeOffset]::Parse([string]$state.conflict_first_at)
                if (([DateTimeOffset]::UtcNow - $first).TotalSeconds -ge $ClaimRetrySeconds) {
                  Write-Log "CONFLICT SETTLED command=$commandId"
                  $state.last_command_id = $commandId
                  $state.conflict_command_id = ""
                  $state.conflict_first_at = ""
                  Save-State $state
                }
              } catch {}
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

    $slots = [Math]::Max(0, $MaxParallelImageChats - @($state.active_image_commands).Count)

    if ($slots -gt 0 -and $CustomMessageSupport) {
      $jobs = @()
      if ($idx -and $idx.jobs) { $jobs = @($idx.jobs) }

      foreach ($job in $jobs) {
        if ($slots -le 0) { break }

        $commandId = [string]$job.command_id
        $targetId = [string]$job.target_id
        if (-not $commandId -or -not $targetId -or (Seen-ImageCommand $state $commandId)) { continue }

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
        $marker = "TT_IMAGE_JOB_V3 $commandId"
        $targetSnapshot=Get-ChatTargetSnapshot

        # Arrancar el bridge ANTES del envío: así toma una línea base real de
        # tabs/rasteres y puede detectar el cambio aunque ChatGPT reutilice el
        # mismo target y la imagen aparezca muy rápido.
        if (-not (Start-ImageBridge $commandId $targetId $uploadSecret $targetSnapshot)) {
          $reason = "No se pudo iniciar el puente local de raster antes del lanzamiento."
          Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
          Mark-ImageCommand $state $commandId $false
          Save-State $state
          continue
        }
        Start-Sleep -Milliseconds 900

        $sent = Launch-ProjectChat "image command=$commandId target=$targetId" $message $marker
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
