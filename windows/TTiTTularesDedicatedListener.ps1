# TTiTTularesDedicatedListener.ps1
# Listener dedicado a TTiTTulares: ejecución editorial + jobs manuales de Gag IA.
# No procesa TTendencias. Editorial e imágenes son flujos independientes.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$ImageBridge = Join-Path $BaseDir "TTiTTularesImageBridge.js"
$StatePath = Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$LauncherLogPath = Join-Path $BaseDir "titulares.log"
$LaunchConfirmSeconds = 30
$StatusBase = "https://europapress-rss.vercel.app"
$ListenerSnapshotUrl = "$StatusBase/api/ttittulares-run-status?view=listener-snapshot"
$ImageJobUrlBase = "$StatusBase/api/ttittulares-run-status?view=image-job&strong=1&id="
$RunUrl = "$StatusBase/api/ttittulares-run"
$WorkerId = "ttittulares-dedicated-v19"
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

function Write-Log([string]$Text) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}


function Ensure-RunnerNewChatCompatibility {
  if (-not (Test-Path -LiteralPath $Runner)) {
    Write-Log "RUNNER COMPAT WARN: no existe $Runner"
    return $false
  }
  try {
    $text = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
    if ($text.Contains("TT_NEW_CHAT_OPTIONAL_V4") -or $text.Contains("TT_NEW_CHAT_OPTIONAL_V3")) {
      return $true
    }

    # Forma actual de Ejecutar.js: abrirNuevoChatProyecto devuelve {ok:false,error:"No encuentro New chat"}
    # y después aborta en el wrapper con throw. Si el botón no existe, continuar con el compositor actual.
    $old = '    if (!r?.ok)' + [Environment]::NewLine +
      '        throw Error(r?.error || "No se puede crear el chat nuevo.");'
    $oldCrLf = '    if (!r?.ok)' + "`r`n" +
      '        throw Error(r?.error || "No se puede crear el chat nuevo.");'

    $replacement = '    /* TT_NEW_CHAT_OPTIONAL_V4 */' + [Environment]::NewLine +
      '    if (!r?.ok) {' + [Environment]::NewLine +
      '        console.log("AVISO: New chat no visible; se usa el compositor actual del proyecto.");' + [Environment]::NewLine +
      '        return;' + [Environment]::NewLine +
      '    }'

    $next = $text
    if ($next.Contains($old)) { $next = $next.Replace($old,$replacement) }
    elseif ($next.Contains($oldCrLf)) { $next = $next.Replace($oldCrLf,$replacement) }
    else {
      Write-Log "RUNNER COMPAT WARN: no se reconoce el wrapper actual de abrirNuevoChatProyecto; no se modifica Ejecutar.js"
      return $false
    }

    foreach ($needle in @(
      'Ejecuta TTiTTulares',
      'Ejecuta TTendencias',
      'TT_CHAT_MESSAGE_B64',
      'const enviar = process.argv.includes("--enviar");',
      'error:"No encuentro New chat"'
    )) {
      if (-not $next.Contains($needle)) { throw "Proteccion fallida: falta $needle" }
    }

    $backup = $Runner + ".before-auto-new-chat-v4-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
    Copy-Item -LiteralPath $Runner -Destination $backup -Force
    Set-Content -LiteralPath $Runner -Value $next -Encoding UTF8

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if ($node) {
      & $node.Source --check $Runner *> $null
      if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $Runner -Force
        throw "node --check fallo; restaurado backup"
      }
    }

    Write-Log "RUNNER COMPAT APPLIED: TT_NEW_CHAT_OPTIONAL_V4 backup=$backup"
    return $true
  } catch {
    Write-Log "RUNNER COMPAT ERROR :: $($_.Exception.Message)"
    return $false
  }
}

function CacheBust([string]$Url) {
  $sep = if ($Url.Contains("?")) { "&" } else { "?" }
  return $Url + $sep + "t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
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
      "User-Agent" = "TTiTTulares-Dedicated-Listener"
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
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
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
    $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/windows/TTiTTularesImageBridge.js?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $doc = Invoke-RestMethod -Uri $api -Headers @{
      "Accept" = "application/vnd.github+json"
      "User-Agent" = "TTiTTulares-image-bridge-refresh"
      "Cache-Control" = "no-cache"
    } -TimeoutSec 15
    if (-not $doc.content) { throw "GitHub API sin contenido" }
    $raw = [Convert]::FromBase64String(([string]$doc.content -replace "\s",""))
    [IO.File]::WriteAllBytes($tmp,$raw)
    $txt = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    foreach ($needle in @(
      'BRIDGE_MODE="capture-only',
      'ttittulares-run-status?view=image-job&strong=1&id=',
      'ttittulares-image-bridge-v1',
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
      if ($txt.Contains('BRIDGE_MODE="capture-only') -and $txt.Contains('ttittulares-run-status?view=image-job&strong=1&id=')) {
        & $NodePath --check $ImageBridge *> $null
        if ($LASTEXITCODE -eq 0) { Write-Log "IMAGE BRIDGE USING VALID LOCAL FALLBACK"; return $true }
      }
    } catch {}
  }
  Write-Log "IMAGE BRIDGE ERROR no hay bridge capture-only válido"
  return $false
}

function Start-ImageBridge([string]$CommandId,[string]$TargetId,[string]$UploadSecret) {
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { Write-Log "IMAGE BRIDGE ERROR node no encontrado"; return $false }
  if (-not (Ensure-ImageBridgeLatest $node.Source)) { return $false }
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $out = Join-Path $BaseDir ("ttittulares-image-bridge-" + $stamp + "-" + $TargetId + ".log")
  $err = Join-Path $BaseDir ("ttittulares-image-bridge-" + $stamp + "-" + $TargetId + ".err.log")
  $old = $env:TT_IMAGE_UPLOAD_SECRET
  try {
    $env:TT_IMAGE_UPLOAD_SECRET = $UploadSecret
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
  }
}

function Launch-ImageChat([string]$Reason,[string]$Message,[string]$ExpectedMarker) {
  if (-not (Test-Path -LiteralPath $Runner)) { return $false }
  Ensure-RunnerNewChatCompatibility | Out-Null
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
  return "TTITTULARES_IMAGE_JOB_V3 $commandId $targetId | Usa ImageGen AHORA y genera UNA imagen IA para '$targetName': gag visual cómico, satírico, irónico y exagerado, no una ilustración literal. Lee ttittulares/image-runs/jobs/$targetId.json en control/ttittulares-run-trigger-v2 para el contexto exacto. No proceses otra entrada ni persistas la imagen: el puente local recoge el raster."
}

function Enable-CustomChatMessages {
  if (-not (Test-Path -LiteralPath $Runner)) {
    Write-Log "CUSTOM MESSAGE DISABLED: no existe $Runner"
    return $false
  }
  try {
    $text = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8

    # MUY IMPORTANTE: este listener solo puede tocar la entrada 'titulares'.
    # TTendencias comparte Ejecutar.js y su línea debe quedar byte-a-byte igual.
    $tendenciasBefore = (($text -split "`r?`n") | Where-Object { $_ -match '^\s*tendencias\s*:' } | Select-Object -First 1)
    if (-not $tendenciasBefore) {
      Write-Log "CUSTOM MESSAGE DISABLED: no se encontró la línea tendencias; no se toca Ejecutar.js"
      return $false
    }

    $exprTit = '(process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTiTTulares")'
    $signature = 'titulares: ' + $exprTit

    if ($text.Contains($signature)) {
      Write-Log "CUSTOM MESSAGE titulares support already present; tendencias preserved"
      return $true
    }

    $next = $text.Replace('titulares: "Ejecuta TTiTTulares"', $signature)
    $next = $next.Replace("titulares: 'Ejecuta TTiTTulares'", $signature)

    if ($next -eq $text) {
      Write-Log "CUSTOM MESSAGE DISABLED: no se encontró la entrada exacta titulares; no se toca TTendencias"
      return $false
    }

    $tendenciasAfter = (($next -split "`r?`n") | Where-Object { $_ -match '^\s*tendencias\s*:' } | Select-Object -First 1)
    if ($tendenciasAfter -cne $tendenciasBefore) {
      Write-Log "CUSTOM MESSAGE ABORTED: la línea tendencias habría cambiado"
      return $false
    }

    $backup = $Runner + ".before-ttittulares-editorial-v12-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
    Copy-Item -LiteralPath $Runner -Destination $backup -Force
    Set-Content -LiteralPath $Runner -Value $next -Encoding UTF8

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if ($node) {
      & $node.Source --check $Runner *> $null
      if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $Runner -Force
        Write-Log "CUSTOM MESSAGE DISABLED: node --check falló; restaurado $backup"
        return $false
      }
    }

    # Verificación final en disco: TTendencias debe seguir idéntico.
    $written = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
    $tendenciasWritten = (($written -split "`r?`n") | Where-Object { $_ -match '^\s*tendencias\s*:' } | Select-Object -First 1)
    if ($tendenciasWritten -cne $tendenciasBefore) {
      Copy-Item -LiteralPath $backup -Destination $Runner -Force
      Write-Log "CUSTOM MESSAGE ABORTED: protección TTendencias activada; backup restaurado"
      return $false
    }

    Write-Log "CUSTOM MESSAGE titulares enabled; TTendencias unchanged; backup=$backup"
    return $true
  } catch {
    Write-Log "CUSTOM MESSAGE ERROR :: $($_.Exception.Message)"
    return $false
  }
}

function Send-Ack([string]$CommandId,[string]$Stage,[string]$Detail = "") {
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
      Write-Log "ACK CONFLICT $Stage command=$CommandId"
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
  return "TTITTULARES_EDITORIAL_JOB_V2 $CommandId | Ejecuta AHORA la pasada editorial real de TTiTTulares. Lee primero ttittulares/editorial-run-prompt.md y el estado autoritativo de ttittulares/editorial-queue.json, ttittulares/status.json y telegram/editorial-processing.json. Procesa TODOS los PROCESSING activos y las reelaboraciones rewrite_pending vigentes. Relee estado antes de declarar cola vacía. NO llames a ImageGen ni generes imágenes en esta pasada. Solo puedes cerrar 0/0 si no queda ningún PROCESSING activo ni rewrite_pending."
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

if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

Write-Log "LISTENER START worker=$WorkerId pid=$PID"
$state = Load-State
Ensure-StateFields $state
Save-State $state
$CustomMessageSupport = Enable-CustomChatMessages

# Diagnóstico inicial: confirma que el proceso sigue vivo y que ve el trigger remoto.
$probe = Read-Trigger
if ($probe -and $probe.command_id) {
  Write-Log "TRIGGER PROBE remote=$($probe.command_id) executor=$($probe.executor) local=$($state.last_command_id)"
} else {
  Write-Log "TRIGGER PROBE FAILED"
}
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
          Write-Log "STALE TRIGGER BASELINED command=$commandId requested_at=$($doc.requested_at)"
          $state.last_command_id = $commandId
          $state.conflict_command_id = ""
          $state.conflict_first_at = ""
          Save-State $state
          Start-Sleep -Seconds $PollSeconds
          continue
        }

        $ack = Send-Ack $commandId "picked_up"

        if ($ack -eq "OK") {
          try {
            $messageSent = Launch-TTiTTulares $commandId
            if ($messageSent) {
              Write-Log "LAUNCH CONFIRMED command=$commandId via=direct-node"
            } else {
              Write-Log "LAUNCH FAILED command=$commandId via=direct-node"
            }
            # Consumir esta orden aunque el lanzamiento falle: evita abrir chats
            # repetidamente cada 3 segundos. Una nueva pulsación crea otro command_id.
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
                # Si otro listener llegó a launched, damos la orden por consumida.
                # Si solo hizo picked_up y murió, el claim del servidor ya habrá caducado
                # y uno de los reintentos anteriores habrá podido tomarlo.
                Write-Log "CONFLICT SETTLED command=$commandId; another listener owns/owned it"
                $state.last_command_id = $commandId
                $state.conflict_command_id = ""
                $state.conflict_first_at = ""
                Save-State $state
              }
            } catch {
              $state.conflict_first_at = [DateTimeOffset]::UtcNow.ToString("o")
              Save-State $state
            }
          }
        }
      }
    }
  } catch {
    Write-Log "LOOP ERROR :: $($_.Exception.Message)"
  }

  # 2) Jobs manuales de Gag IA (separados de la ejecución editorial)
  try {
    $idx=Read-ImageIndex
    Refresh-ActiveImages $state $idx
    Save-State $state
    $slots=[Math]::Max(0,$MaxParallelImageChats-@($state.active_image_commands).Count)
    if($slots -gt 0 -and $CustomMessageSupport){
      $jobs=@();if($idx -and $idx.jobs){$jobs=@($idx.jobs)}
      foreach($job in $jobs){
        if($slots -le 0){break}
        $commandId=[string]$job.command_id
        $targetId=[string]$job.target_id
        if(-not $commandId -or -not $targetId -or (Seen-ImageCommand $state $commandId)){continue}
        $recent=$true
        try{$requested=[DateTimeOffset]::Parse([string]$job.requested_at);if(([DateTimeOffset]::UtcNow-$requested).TotalHours -gt 12){$recent=$false}}catch{}
        if(-not $recent){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        $statusDoc=Read-ImageJob $targetId
        if(-not $statusDoc -or [string]$statusDoc.command_id -ne $commandId){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        if(Is-TerminalImageStatus ([string]$statusDoc.status)){Mark-ImageCommand $state $commandId $false;Save-State $state;continue}
        Write-Log "IMAGE NEW target=$targetId command=$commandId name=$($job.target_name)"
        $uploadSecret=New-ImageUploadSecret
        $uploadHash=Get-Sha256Hex $uploadSecret
        if(-not (Send-ImageAck $targetId $commandId "picked_up" "" $uploadHash "")){continue}
        $message=Build-ImageMessage $job
        $marker="TTITTULARES_IMAGE_JOB_V3 $commandId"
        $sent=Launch-ImageChat "image command=$commandId target=$targetId" $message $marker
        if($sent){
          Send-ImageAck $targetId $commandId "launched" | Out-Null
          if(-not (Start-ImageBridge $commandId $targetId $uploadSecret)){
            $reason="El chat arrancó, pero no se pudo iniciar el puente local de raster."
            Send-ImageAck $targetId $commandId "failed" $reason "" $uploadSecret | Out-Null
            Mark-ImageCommand $state $commandId $false;Save-State $state;continue
          }
          Mark-ImageCommand $state $commandId $true;Save-State $state;$slots--
        }else{
          # La telemetría de Ejecutar.js puede faltar aunque el mensaje haya llegado
          # al chat. El bridge valida el marker real del command_id y es la autoridad
          # para decidir si el hand-off existió.
          $reason="Ejecutar.js no confirmó el envío en $($LaunchConfirmSeconds) s.; delegando confirmación real al bridge."
          Write-Log "IMAGE CHAT UNCONFIRMED; BRIDGE WILL VERIFY target=$targetId command=$commandId :: $reason"
          Send-ImageAck $targetId $commandId "launched" | Out-Null
          if(-not (Start-ImageBridge $commandId $targetId $uploadSecret)){
            $failReason="El lanzamiento quedó sin confirmar y tampoco se pudo iniciar el puente local de raster."
            Send-ImageAck $targetId $commandId "failed" $failReason "" $uploadSecret | Out-Null
            Mark-ImageCommand $state $commandId $false;Save-State $state;continue
          }
          Mark-ImageCommand $state $commandId $true;Save-State $state;$slots--
        }
      }
    }elseif($slots -gt 0 -and -not $CustomMessageSupport){
      Write-Log "IMAGE QUEUE WAITING: custom message support unavailable"
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
