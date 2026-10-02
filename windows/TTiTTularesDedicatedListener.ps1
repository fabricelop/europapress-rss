# TTiTTularesDedicatedListener.ps1
# Listener dedicado SOLO a ejecuciones editoriales de TTiTTulares.
# No procesa TTendencias ni trabajos de imagen IA.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$StatePath = Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$LauncherLogPath = Join-Path $BaseDir "titulares.log"
$LaunchConfirmSeconds = 45
$TriggerApiUrl = "https://europapress-rss.vercel.app/api/ttittulares-run-status?view=trigger"
$RunUrl = "https://europapress-rss.vercel.app/api/ttittulares-run"
$WorkerId = "ttittulares-dedicated-v8"
$PollSeconds = 5
$ClaimRetrySeconds = 38
$MaxTriggerAgeSeconds = 90

function Write-Log([string]$Text) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function CacheBust([string]$Url) {
  $sep = if ($Url.Contains("?")) { "&" } else { "?" }
  return $Url + $sep + "t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Read-Trigger {
  try {
    $r = Invoke-RestMethod -Uri (CacheBust $TriggerApiUrl) -Headers @{
      "Cache-Control" = "no-cache"
      "User-Agent" = "TTiTTulares-Dedicated-Listener"
    } -TimeoutSec 12
    if (-not $r.ok) { throw "Endpoint trigger devolvio ok=false" }
    if ($r.trigger) { return $r.trigger }
    return $r
  } catch {
    Write-Log "TRIGGER ERROR :: $($_.Exception.Message)"
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
    $next = $text.Replace('"Ejecuta TTiTTulares"', $exprTit).Replace("'Ejecuta TTiTTulares'", $exprTit)

    if ($next -eq $text) {
      Write-Log "CUSTOM MESSAGE DISABLED: no se encontró el literal Ejecuta TTiTTulares"
      return $false
    }

    $backup = $Runner + ".before-ttittulares-editorial-marker-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
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

function Launch-TTiTTulares([string]$CommandId) {
  if (-not (Test-Path -LiteralPath $Launcher)) {
    $detail = "No existe $Launcher"
    Write-Log "EDITORIAL PROCESS ERROR command=$CommandId :: $detail"
    [void](Send-Ack $CommandId "failed" $detail)
    return $false
  }

  $beforeWrite = [DateTime]::MinValue
  $beforeLen = 0L
  if (Test-Path -LiteralPath $LauncherLogPath) {
    try {
      $fi = Get-Item -LiteralPath $LauncherLogPath
      $beforeWrite = $fi.LastWriteTimeUtc
      $beforeLen = $fi.Length
    } catch {}
  }

  $marker = "TT_EDITORIAL_WORKER_V1 $CommandId"
  $message = @"
$marker
Ejecuta TTiTTulares directamente en este chat como worker editorial de la orden ya recogida por el PC.
NO crees ni modifiques run-now-trigger.json.
NO solicites otra ejecución y NO lances otro chat.
Usa command_id $CommandId para la telemetría/RUNTRACE de esta pasada.
Procesa las Entradas pendientes siguiendo el flujo editorial normal de TTiTTulares.
"@

  $old = $env:TT_CHAT_MESSAGE_B64
  $proc = $null
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String($bytes)

    $proc = Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,"titulares") -WindowStyle Hidden -PassThru
    if (-not $proc) { throw "Start-Process no devolvió proceso" }

    Write-Log "EDITORIAL PROCESS STARTED via-vbs-custom pid=$($proc.Id) command=$CommandId marker=$marker"
  } catch {
    $detail = "No se pudo lanzar LanzarOculto.vbs titulares: $($_.Exception.Message)"
    Write-Log "EDITORIAL PROCESS ERROR command=$CommandId :: $detail"
    [void](Send-Ack $CommandId "failed" $detail)
    return $false
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

      $tail = @(Get-Content -LiteralPath $LauncherLogPath -Tail 80 -ErrorAction Stop)
      $joined = ($tail -join "`n")
      $hasMarker = $joined.Contains($marker)
      $responseStarted = $joined -match '"generando"\s*:\s*true'
      $messageSent = $joined -match "MENSAJE ENVIADO"
      $executionLaunched = $joined -match "EJECUCION LANZADA"

      if ($hasMarker -and ($messageSent -or $executionLaunched -or $responseStarted)) {
        $why = if ($responseStarted) { "generando:true" } elseif ($executionLaunched) { "EJECUCION LANZADA" } else { "MENSAJE ENVIADO" }
        Write-Log "CHAT MESSAGE CONFIRMED command=$CommandId marker=$marker via=$why"
        $launched = Send-Ack $CommandId "launched"
        if ($launched -ne "OK") {
          Write-Log "LAUNCHED ACK WARNING command=$CommandId result=$launched"
        }
        return $true
      }

      if ($hasMarker -and $joined -match "ERROR:|ERROR ::|Timeout CDP") {
        $last = ($tail | Where-Object { $_ -match "ERROR:|ERROR ::|Timeout CDP" } | Select-Object -Last 1)
        $detail = "Ejecutar.js: $last"
        Write-Log "CHAT LAUNCH LOG ERROR command=$CommandId :: $detail"
        [void](Send-Ack $CommandId "failed" $detail)
        return $false
      }
    } catch {}
  }

  $detail = "VBS arrancó pero ChatGPT no confirmó el mensaje en $($LaunchConfirmSeconds)s"
  Write-Log "CHAT MESSAGE TIMEOUT command=$CommandId marker=$marker"
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
              Write-Log "LAUNCH CONFIRMED command=$commandId via=vbs-log"
            } else {
              Write-Log "LAUNCH FAILED command=$commandId via=vbs-log"
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
  if (($loopCount % 20) -eq 0) {
    try {
      $hb = Read-Trigger
      if ($hb -and $hb.command_id) {
        Write-Log "HEARTBEAT remote=$($hb.command_id) executor=$($hb.executor) local=$($state.last_command_id)"
      } else {
        Write-Log "HEARTBEAT trigger_unavailable"
      }
    } catch {}
  }
  Start-Sleep -Seconds $PollSeconds
}
