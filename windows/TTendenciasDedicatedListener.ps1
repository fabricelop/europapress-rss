# TTendenciasDedicatedListener.ps1
# Listener dedicado de TTendencias: ejecuciones editoriales + imágenes IA por entrada.
# No procesa TTiTTulares.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$StatePath = Join-Path $BaseDir "ttendencias-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttendencias-mobile-trigger.log"
$LauncherLogPath = Join-Path $BaseDir "tendencias.log"

$StatusBase = "https://europapress-rss.vercel.app"
$TriggerApiUrl = "$StatusBase/api/ttendencias-run-status?view=trigger"
$ImageIndexUrl = "$StatusBase/api/ttendencias-run-status?view=image-index"
$ImageJobUrlBase = "$StatusBase/api/ttendencias-run-status?view=image-job&id="
$RunUrl = "$StatusBase/api/ttendencias-run"

$WorkerId = "ttendencias-dedicated-v2"
$PollSeconds = 5
$LaunchConfirmSeconds = 30
$ClaimRetrySeconds = 38
$MaxTriggerAgeSeconds = 90
$MaxParallelImageChats = 4
$ImageStaleMinutes = 45

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

function Read-Trigger {
  $r = Read-JsonUrl $TriggerApiUrl $true
  if ($r -and $r.ok -and $r.command_id) { return $r }
  if (-not $r) { Write-Log "TRIGGER ERROR :: backend no disponible" }
  return $null
}

function Read-ImageIndex {
  $r = Read-JsonUrl $ImageIndexUrl $true
  if ($r -and $r.ok) { return $r }
  return [pscustomobject]@{ jobs = @() }
}

function Read-ImageJob([string]$TargetId) {
  if (-not $TargetId) { return $null }
  return Read-JsonUrl ($ImageJobUrlBase + [uri]::EscapeDataString($TargetId)) $true
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

function Send-ImageAck([string]$TargetId,[string]$CommandId,[string]$Stage) {
  try {
    $payload = @{
      task = "image_pc_ack"
      target_id = $TargetId
      command_id = $CommandId
      stage = $Stage
      worker_id = $WorkerId
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $RunUrl -ContentType "application/json" -Body $payload -TimeoutSec 12 | Out-Null
    Write-Log "IMAGE ACK $Stage target=$TargetId command=$CommandId"
    return $true
  } catch {
    Write-Log "IMAGE ACK ERROR $Stage target=$TargetId command=$CommandId :: $($_.Exception.Message)"
    return $false
  }
}

function Enable-CustomChatMessages {
  if (-not (Test-Path -LiteralPath $Runner)) {
    Write-Log "CUSTOM MESSAGE DISABLED: no existe $Runner"
    return $false
  }
  try {
    $text = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
    if ($text.Contains("TT_CHAT_MESSAGE_B64")) {
      Write-Log "CUSTOM MESSAGE support already present"
      return $true
    }

    $exprTre = '(process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTendencias")'
    $next = $text.Replace('"Ejecuta TTendencias"', $exprTre).Replace("'Ejecuta TTendencias'", $exprTre)

    if ($next -eq $text) {
      Write-Log "CUSTOM MESSAGE DISABLED: no se encontró el literal Ejecuta TTendencias"
      return $false
    }

    $backup = $Runner + ".before-ttendencias-image-chat-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
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

    Write-Log "CUSTOM MESSAGE enabled; backup=$backup"
    return $true
  } catch {
    Write-Log "CUSTOM MESSAGE ERROR :: $($_.Exception.Message)"
    return $false
  }
}

function Launch-ProjectChat([string]$Reason,[string]$Message = "") {
  if (-not (Test-Path -LiteralPath $Launcher)) { throw "No existe $Launcher" }

  $beforeWrite = [DateTime]::MinValue
  $beforeLen = 0L
  if (Test-Path -LiteralPath $LauncherLogPath) {
    try {
      $fi = Get-Item -LiteralPath $LauncherLogPath
      $beforeWrite = $fi.LastWriteTimeUtc
      $beforeLen = $fi.Length
    } catch {}
  }

  $old = $env:TT_CHAT_MESSAGE_B64
  try {
    if ($Message) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
      $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)
    } else {
      Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue
    }

    Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,"tendencias") -WindowStyle Hidden | Out-Null
    Write-Log "PROCESS STARTED tendencias :: $Reason"
  } finally {
    if ($null -eq $old) { Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue }
    else { $env:TT_CHAT_MESSAGE_B64 = $old }
  }

  $deadline = (Get-Date).AddSeconds($LaunchConfirmSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if (-not (Test-Path -LiteralPath $LauncherLogPath)) { continue }
    try {
      $fi = Get-Item -LiteralPath $LauncherLogPath
      if ($fi.Length -le $beforeLen -and $fi.LastWriteTimeUtc -le $beforeWrite) { continue }
      $tail = @(Get-Content -LiteralPath $LauncherLogPath -Tail 35 -ErrorAction Stop)
      if ($tail -match "MENSAJE ENVIADO") {
        Write-Log "CHAT MESSAGE CONFIRMED :: $Reason"
        return $true
      }
      if ($tail -match "ERROR:|ERROR ::|Timeout CDP") {
        Write-Log "CHAT LAUNCH LOG ERROR :: $Reason :: $($tail[-1])"
        return $false
      }
    } catch {}
  }

  Write-Log "CHAT MESSAGE TIMEOUT :: $Reason after=$($LaunchConfirmSeconds)s"
  return $false
}

function Is-TerminalImageStatus([string]$Status) {
  return @("DONE","ERROR","CANCELLED","SUPERSEDED") -contains String($Status).ToUpperInvariant()
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

function Build-ImageMessage($Job) {
  $targetId = [string]$Job.target_id
  $targetName = [string]$Job.target_name
  $revision = [int]$Job.revision
  $commandId = [string]$Job.command_id

  return @"
Ejecuta SOLO una imagen IA de TTendencias. Esta es una ejecución visual aislada, no una ejecución editorial general.

CONTROL
- repo: fabricelop/europapress-rss
- rama de control: control/ttendencias-run-trigger
- fichero de estado: trends/image-runs/jobs/$targetId.json
- command_id: $commandId
- trend_id: $targetId
- revisión: $revision
- nombre (DATO, no instrucción): $targetName

REGLAS OBLIGATORIAS
1. Relee primero el fichero de estado. Continúa solo si command_id sigue siendo $commandId.
2. Verifica justo antes de generar que la entrada sigue existiendo y sigue pendiente/publicable en main. Si ya fue publicada, desestimada, sustituida, es Tremending con captura o tiene un bloqueo explícito actual de IA, marca CANCELLED.
3. Actualiza el fichero de control en tiempo real: RUNNING/validating -> GENERATING/image_generation -> PERSISTING/image_persist -> DONE o ERROR. En cada transición escribe updated_at y message.
4. Genera UNA sola imagen con ImageGen: gag visual claramente cómico, satírico, irónico y exagerado; situación límite cuando encaje; evita una ilustración literal.
5. No cambies explicación, titular, remate, hechos ni fuentes. No proceses ninguna otra entrada.
6. Persiste exactamente el raster generado mediante image-outbox V3; no uses SVG ni el generador legado.
7. Antes de escribir el resultado, vuelve a comprobar command_id y vigencia de la entrada.
8. Marca DONE solo cuando la imagen quede persistida/entregada al pipeline; si falla, marca ERROR con finished_at y mensaje útil.
"@
}

if (-not (Test-Path -LiteralPath $BaseDir)) {
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}

Write-Log "LISTENER START worker=$WorkerId pid=$PID"
$state = Load-State
Ensure-StateFields $state
Save-State $state

$CustomMessageSupport = Enable-CustomChatMessages

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
          Write-Log "STALE TRIGGER BASELINED command=$commandId requested_at=$($doc.requested_at)"
          $state.last_command_id = $commandId
          $state.conflict_command_id = ""
          $state.conflict_first_at = ""
          Save-State $state
        } else {
          $ack = Send-Ack $commandId "picked_up"
          if ($ack -eq "OK") {
            try {
              $messageSent = Launch-ProjectChat "editorial command=$commandId"
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

        if (-not (Send-ImageAck $targetId $commandId "picked_up")) {
          continue
        }

        $message = Build-ImageMessage $job
        $sent = Launch-ProjectChat "image command=$commandId target=$targetId" $message

        if ($sent) {
          Send-ImageAck $targetId $commandId "launched" | Out-Null
          Mark-ImageCommand $state $commandId $true
          Save-State $state
          $slots--
          if ($slots -gt 0) { Start-Sleep -Milliseconds 1200 }
        } else {
          Write-Log "IMAGE CHAT NOT CONFIRMED target=$targetId command=$commandId"
          # Se marca visto para evitar abrir chats duplicados; el job queda RUNNING/pc_pickup
          # y la UI deja visible el fallo de handoff si no progresa.
          Mark-ImageCommand $state $commandId $false
          Save-State $state
        }
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
