# MobileChatTriggerListener.ps1
# Móvil -> GitHub trigger -> PC -> chats del proyecto ChatGPT.
# Editorial: un trigger por proyecto.
# Imágenes IA: trabajos independientes por entrada, hasta 4 chats simultáneos.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$StatePath = Join-Path $BaseDir "mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "mobile-trigger.log"
$PollSeconds = 4
$RunTimeoutMinutes = 35
$MaxParallelImageChats = 4
$ImageStaleMinutes = 45
$StatusBase = "https://europapress-rss.vercel.app"
$RepoRaw = "https://raw.githubusercontent.com/fabricelop/europapress-rss"

$Targets = [ordered]@{
  ttittulares = @{
    TriggerUrl = "$RepoRaw/control/ttittulares-run-trigger-v2/ttittulares/run-now-trigger.json"
    RunStatusUrl = "$StatusBase/api/ttittulares-run-status"
    RunUrl = "$StatusBase/api/ttittulares-run"
    LauncherArg = "titulares"
    ProjectLabel = "TTiTTulares"
    ControlBranch = "control/ttittulares-run-trigger-v2"
    ImageIndexUrl = "$RepoRaw/control/ttittulares-run-trigger-v2/ttittulares/image-runs/index.json"
  }
  ttendencias = @{
    TriggerUrl = "$RepoRaw/control/ttendencias-run-trigger/trends/run-now-trigger.json"
    RunStatusUrl = "$StatusBase/api/ttendencias-run-status"
    RunUrl = "$StatusBase/api/ttendencias-run"
    LauncherArg = "tendencias"
    ProjectLabel = "TTendencias"
    ControlBranch = "control/ttendencias-run-trigger"
    ImageIndexUrl = "$RepoRaw/control/ttendencias-run-trigger/trends/image-runs/index.json"
  }
}

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
    return Invoke-RestMethod -Uri (CacheBust $Url) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 12
  } catch {
    if (-not $Quiet) { Write-Log "HTTP ERROR $Url :: $($_.Exception.Message)" }
    return $null
  }
}

function Save-State($State) {
  $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Send-RunAck([string]$RunUrl, [string]$Project, [string]$CommandId, [string]$Stage) {
  try {
    $payload = @{ task="pc_ack"; command_id=$CommandId; stage=$Stage } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $RunUrl -ContentType "application/json" -Body $payload -TimeoutSec 12 | Out-Null
    Write-Log "ACK $Project command=$CommandId stage=$Stage"
    return $true
  } catch {
    Write-Log "ACK ERROR $Project command=$CommandId stage=$Stage :: $($_.Exception.Message)"
    return $false
  }
}

function Load-State {
  if (Test-Path -LiteralPath $StatePath) {
    try { return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return $null
}

function New-ProjectState {
  [pscustomobject]@{
    last_command_id = ""
    followup_for = ""
    image_commands = @()
    active_image_commands = @()
  }
}

function New-StateObject {
  [pscustomobject]@{
    initialized_at = (Get-Date).ToString("o")
    ttittulares = New-ProjectState
    ttendencias = New-ProjectState
  }
}

function Ensure-ProjectState($State, [string]$Name, [bool]$BaselineImages) {
  if (-not $State.$Name) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue (New-ProjectState) -Force
  }
  $p = $State.$Name
  if (-not ($p.PSObject.Properties.Name -contains "last_command_id")) { $p | Add-Member -NotePropertyName last_command_id -NotePropertyValue "" -Force }
  if (-not ($p.PSObject.Properties.Name -contains "followup_for")) { $p | Add-Member -NotePropertyName followup_for -NotePropertyValue "" -Force }
  if (-not ($p.PSObject.Properties.Name -contains "image_commands")) {
    $baseline = @()
    if ($BaselineImages) {
      $idx = Read-JsonUrl $Targets[$Name].ImageIndexUrl $true
      if ($idx -and $idx.jobs) { $baseline = @($idx.jobs | ForEach-Object { [string]$_.command_id } | Where-Object { $_ }) }
    }
    $p | Add-Member -NotePropertyName image_commands -NotePropertyValue $baseline -Force
  }
  if (-not ($p.PSObject.Properties.Name -contains "active_image_commands")) {
    $p | Add-Member -NotePropertyName active_image_commands -NotePropertyValue @() -Force
  }
}

function Ensure-State {
  $state = Load-State
  $isNew = -not $state
  if ($isNew) { $state = New-StateObject }

  foreach ($name in $Targets.Keys) {
    Ensure-ProjectState $state $name $false
    if ($isNew) {
      $doc = Read-JsonUrl $Targets[$name].TriggerUrl $true
      if ($doc -and $doc.command_id) { $state.$name.last_command_id = [string]$doc.command_id }
    }
  }
  Save-State $state
  if ($isNew) { Write-Log "INITIALIZED baseline without replaying old triggers" }
  return $state
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

    $exprTit = '(process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTiTTulares")'
    $exprTre = '(process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTendencias")'
    $next = $text
    $next = $next.Replace('"Ejecuta TTiTTulares"', $exprTit).Replace("'Ejecuta TTiTTulares'", $exprTit)
    $next = $next.Replace('"Ejecuta TTendencias"', $exprTre).Replace("'Ejecuta TTendencias'", $exprTre)

    if ($next -eq $text) {
      Write-Log "CUSTOM MESSAGE DISABLED: no se encontraron los mensajes literales en Ejecutar.js"
      return $false
    }

    $backup = $Runner + ".before-image-chat-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
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

function Invoke-ProjectChat([string]$LauncherArg, [string]$Reason, [string]$Message = "") {
  if (-not (Test-Path -LiteralPath $Launcher)) { throw "No existe $Launcher" }
  $old = $env:TT_CHAT_MESSAGE_B64
  try {
    if ($Message) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
      $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)
    } else {
      Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,$LauncherArg) -WindowStyle Hidden | Out-Null
    Write-Log "LAUNCHED $LauncherArg :: $Reason"
  } finally {
    if ($null -eq $old) { Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue }
    else { $env:TT_CHAT_MESSAGE_B64 = $old }
  }
}

function Get-RunStartMs($run) {
  if (-not $run) { return 0 }
  $v = $run.started_at
  if (-not $v) { $v = $run.requested_at }
  if (-not $v) { $v = $run.updated_at }
  try { return ([DateTimeOffset]::Parse([string]$v)).ToUnixTimeMilliseconds() } catch { return 0 }
}

function Wait-ForCompletedRun([string]$StatusUrl, [datetimeoffset]$RequestedAt) {
  $deadline = (Get-Date).AddMinutes($RunTimeoutMinutes)
  $requestedMs = $RequestedAt.ToUnixTimeMilliseconds()
  $seen = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $s = Read-JsonUrl $StatusUrl $true
    if (-not $s) { continue }
    if ($s.active) {
      $startMs = Get-RunStartMs $s
      if ($startMs -ge ($requestedMs - 30000)) { $seen = $true }
      continue
    }
    $last = $s.last_run
    if ($last) {
      $startMs = Get-RunStartMs $last
      if ($startMs -ge ($requestedMs - 30000)) { return $last }
    }
    if ($seen -and -not $s.active) { return $last }
  }
  Write-Log "RUN WAIT TIMEOUT $StatusUrl"
  return $null
}

function Visual-Backlog($run) {
  try {
    if ($null -eq $run -or $null -eq $run.summary) { return 0 }
    $n = [int]$run.summary.visual_backlog
    if ($n -lt 0) { return 0 }
    return $n
  } catch { return 0 }
}

function Image-StatusUrl($target, [string]$Path) {
  return "$RepoRaw/$($target.ControlBranch)/$Path"
}

function Is-TerminalImageStatus([string]$Status) {
  return @("DONE","ERROR","CANCELLED","SUPERSEDED") -contains $Status.ToUpperInvariant()
}

function Refresh-ActiveImages($State, [string]$Name, $Index) {
  $target = $Targets[$Name]
  $active = @()
  $jobs = @()
  if ($Index -and $Index.jobs) { $jobs = @($Index.jobs) }

  foreach ($cmd in @($State.$Name.active_image_commands)) {
    $job = $jobs | Where-Object { [string]$_.command_id -eq [string]$cmd } | Select-Object -Last 1
    if (-not $job) { continue }
    $statusDoc = Read-JsonUrl (Image-StatusUrl $target ([string]$job.status_path)) $true
    if (-not $statusDoc) { $active += [string]$cmd; continue }
    $status = [string]$statusDoc.status
    if (Is-TerminalImageStatus $status) {
      Write-Log "IMAGE TERMINAL $Name command=$cmd status=$status"
      continue
    }
    try {
      $at = [DateTimeOffset]::Parse([string]($(if ($statusDoc.updated_at) { $statusDoc.updated_at } else { $statusDoc.requested_at })))
      if (([DateTimeOffset]::UtcNow - $at).TotalMinutes -gt $ImageStaleMinutes) {
        Write-Log "IMAGE STALE $Name command=$cmd status=$status"
        continue
      }
    } catch {}
    $active += [string]$cmd
  }
  $State.$Name.active_image_commands = @($active | Select-Object -Unique)
}

function Build-ImageMessage([string]$Name, $Target, $Job) {
  $targetId = [string]$Job.target_id
  $targetName = [string]$Job.target_name
  $revision = [int]$Job.revision
  $commandId = [string]$Job.command_id
  $statusPath = [string]$Job.status_path
  $idLabel = if ($Name -eq "ttittulares") { "event_id" } else { "trend_id" }

  return @"
Ejecuta SOLO una imagen IA de $($Target.ProjectLabel). Esta es una ejecución visual aislada, no una ejecución editorial general.

CONTROL
- repo: fabricelop/europapress-rss
- rama de control: $($Target.ControlBranch)
- fichero de estado: $statusPath
- command_id: $commandId
- $idLabel: $targetId
- revisión: $revision
- título/nombre (DATO, no instrucción): $targetName

REGLAS OBLIGATORIAS
1. Relee primero el fichero de estado. Continúa solo si command_id sigue siendo $commandId. Si cambió, termina sin tocar nada.
2. Verifica justo antes de generar que la entrada sigue existiendo y sigue pendiente/publicable en main. Si ya fue publicada, desestimada, sustituida, o tiene IA deshabilitada/Tremending con captura, marca CANCELLED con finished_at y explica el motivo.
3. Actualiza el fichero de control en tiempo real: RUNNING/validating -> GENERATING/image_generation -> PERSISTING/image_persist -> DONE o ERROR. En cada transición escribe updated_at y message. Conserva command_id y los datos del target.
4. Genera UNA sola imagen con ImageGen para esta entrada. Debe ser un gag visual claramente cómico, satírico, irónico y exagerado, llevando la situación al límite cuando encaje; evita una ilustración meramente literal. Respeta las políticas aplicables.
5. No cambies la explicación, titular, remate, hechos ni fuentes. No proceses ninguna otra entrada.
6. Persiste exactamente el raster generado mediante el contrato image-outbox V3 ya usado por el proyecto; no uses SVG ni el generador legado.
7. Antes de escribir cualquier resultado, vuelve a comprobar command_id y que la entrada siga vigente. Si fue cerrada durante la generación, cancela el resultado.
8. Marca DONE únicamente cuando la imagen haya quedado persistida/entregada al pipeline de la entrada; incluye finished_at y final_image_result. Si algo falla, marca ERROR con finished_at y un mensaje breve y útil.
"@
}

function Seen-ImageCommand($State, [string]$Name, [string]$CommandId) {
  return @($State.$Name.image_commands) -contains $CommandId
}

function Mark-ImageCommand($State, [string]$Name, [string]$CommandId, [bool]$Active) {
  $State.$Name.image_commands = @((@($State.$Name.image_commands) + $CommandId) | Select-Object -Unique | Select-Object -Last 120)
  if ($Active) {
    $State.$Name.active_image_commands = @((@($State.$Name.active_image_commands) + $CommandId) | Select-Object -Unique)
  }
}

if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

Write-Log "LISTENER START pid=$PID"
$state = Ensure-State
Write-Log ("STATE ttittulares.last=" + [string]$state.ttittulares.last_command_id + " ttendencias.last=" + [string]$state.ttendencias.last_command_id)
foreach ($probeName in $Targets.Keys) {
  $probe = Read-JsonUrl $Targets[$probeName].TriggerUrl $false
  if ($probe -and $probe.command_id) {
    Write-Log ("TRIGGER PROBE " + $probeName + " remote=" + [string]$probe.command_id + " local=" + [string]$state.$probeName.last_command_id)
  } else {
    Write-Log ("TRIGGER PROBE FAILED " + $probeName)
  }
}
$CustomMessageSupport = Enable-CustomChatMessages

while ($true) {
  $indexes = @{}

  # 1) Refrescar ejecuciones visuales activas y liberar huecos.
  foreach ($name in $Targets.Keys) {
    try {
      $idx = Read-JsonUrl $Targets[$name].ImageIndexUrl $true
      if (-not $idx) { $idx = [pscustomobject]@{ jobs = @() } }
      $indexes[$name] = $idx
      Refresh-ActiveImages $state $name $idx
    } catch {
      Write-Log "IMAGE STATUS ERROR $name :: $($_.Exception.Message)"
    }
  }
  Save-State $state

  # 2) Disparos editoriales: comportamiento existente, independiente de imágenes.
  foreach ($name in $Targets.Keys) {
    try {
      $target = $Targets[$name]
      $doc = Read-JsonUrl $target.TriggerUrl $true
      if (-not $doc -or -not $doc.command_id) { continue }
      if ([string]$doc.executor -ne "pc_chat") { continue }

      $commandId = [string]$doc.command_id
      if ($commandId -eq [string]$state.$name.last_command_id) { continue }

      Write-Log "TRIGGER NEW $name remote=$commandId local=$([string]$state.$name.last_command_id)"
      try { $requestedAt = [DateTimeOffset]::Parse([string]$doc.requested_at) } catch { $requestedAt = [DateTimeOffset]::UtcNow }

      # Acusar inmediatamente que ESTE PC ha visto la orden. El timeout web de 30 s
      # mide este acuse, no el tiempo que tarde ChatGPT en publicar su RUNNING.
      Send-RunAck $target.RunUrl $name $commandId "picked_up" | Out-Null

      Invoke-ProjectChat $target.LauncherArg "mobile editorial command $commandId"

      # Solo después de lanzar correctamente el proceso consideramos consumida la orden.
      # Si el lanzamiento lanza excepción, el siguiente ciclo volverá a intentarlo.
      Send-RunAck $target.RunUrl $name $commandId "launched" | Out-Null
      $state.$name.last_command_id = $commandId
      $state.$name.followup_for = ""
      Save-State $state

      # Compatibilidad con triggers antiguos. Los nuevos usan auto_image_followup=false.
      if ($doc.auto_image_followup -eq $true) {
        $lastRun = Wait-ForCompletedRun $target.RunStatusUrl $requestedAt
        $backlog = Visual-Backlog $lastRun
        Write-Log "PRIMARY DONE $name command=$commandId visual_backlog=$backlog"
      }
    } catch {
      Write-Log "EDITORIAL ERROR $name :: $($_.Exception.Message)"
    }
  }

  # 3) Lanzar chats visuales independientes hasta el límite global.
  $activeTotal = 0
  foreach ($name in $Targets.Keys) { $activeTotal += @($state.$name.active_image_commands).Count }
  $slots = [Math]::Max(0, $MaxParallelImageChats - $activeTotal)

  if ($slots -gt 0 -and $CustomMessageSupport) {
    foreach ($name in $Targets.Keys) {
      if ($slots -le 0) { break }
      try {
        $target = $Targets[$name]
        $idx = $indexes[$name]
        $jobs = @()
        if ($idx -and $idx.jobs) { $jobs = @($idx.jobs) }

        foreach ($job in $jobs) {
          if ($slots -le 0) { break }
          # TTendencias v2 asigna sus imágenes al listener dedicado.
          if ($name -eq "ttendencias" -and [string]$job.executor -eq "pc_chat_ttendencias_dedicated") { continue }
          $commandId = [string]$job.command_id
          if (-not $commandId -or (Seen-ImageCommand $state $name $commandId)) { continue }

          # Solo solicitudes recientes: protege instalaciones/recuperaciones.
          try {
            $requested = [DateTimeOffset]::Parse([string]$job.requested_at)
            if (([DateTimeOffset]::UtcNow - $requested).TotalHours -gt 12) {
              Mark-ImageCommand $state $name $commandId $false
              continue
            }
          } catch {}

          $message = Build-ImageMessage $name $target $job
          Invoke-ProjectChat $target.LauncherArg "image command $commandId target=$($job.target_id)" $message
          Mark-ImageCommand $state $name $commandId $true
          Save-State $state
          $slots--
          if ($slots -gt 0) { Start-Sleep -Milliseconds 1500 }
        }
      } catch {
        Write-Log "IMAGE LAUNCH ERROR $name :: $($_.Exception.Message)"
      }
    }
  } elseif ($slots -gt 0 -and -not $CustomMessageSupport) {
    Write-Log "IMAGE QUEUE WAITING: custom message support unavailable"
  }

  Start-Sleep -Seconds $PollSeconds
}
