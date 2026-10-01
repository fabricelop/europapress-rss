# TTiTTularesDedicatedListener.ps1
# Listener dedicado SOLO a ejecuciones editoriales de TTiTTulares.
# No procesa TTendencias ni trabajos de imagen IA.

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$StatePath = Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$LauncherLogPath = Join-Path $BaseDir "titulares.log"
$LaunchConfirmSeconds = 30
$TriggerApiUrl = "https://api.github.com/repos/fabricelop/europapress-rss/contents/ttittulares/run-now-trigger.json?ref=control%2Fttittulares-run-trigger-v2"
$RunUrl = "https://europapress-rss.vercel.app/api/ttittulares-run"
$WorkerId = "ttittulares-dedicated-v1"
$PollSeconds = 3
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
      "Accept" = "application/vnd.github+json"
      "User-Agent" = "TTiTTulares-Dedicated-Listener"
    } -TimeoutSec 12
    if (-not $r.content) { throw "GitHub API devolvió trigger sin content" }
    $b64 = ([string]$r.content) -replace "\s",""
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    return ($json | ConvertFrom-Json)
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

function Send-Ack([string]$CommandId,[string]$Stage) {
  try {
    $payload = @{
      task = "pc_ack"
      command_id = $CommandId
      stage = $Stage
      worker_id = $WorkerId
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

function Launch-TTiTTulares([string]$CommandId) {
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

  Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,"titulares") -WindowStyle Hidden | Out-Null
  Write-Log "PROCESS STARTED titulares command=$CommandId"

  $deadline = (Get-Date).AddSeconds($LaunchConfirmSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if (-not (Test-Path -LiteralPath $LauncherLogPath)) { continue }
    try {
      $fi = Get-Item -LiteralPath $LauncherLogPath
      if ($fi.Length -le $beforeLen -and $fi.LastWriteTimeUtc -le $beforeWrite) { continue }
      $tail = @(Get-Content -LiteralPath $LauncherLogPath -Tail 30 -ErrorAction Stop)
      if ($tail -match "MENSAJE ENVIADO") {
        Write-Log "CHAT MESSAGE CONFIRMED titulares command=$CommandId"
        return $true
      }
      if ($tail -match "ERROR:|ERROR ::|Timeout CDP") {
        Write-Log "CHAT LAUNCH LOG ERROR command=$CommandId :: $($tail[-1])"
        return $false
      }
    } catch {}
  }

  Write-Log ("CHAT MESSAGE TIMEOUT command=" + $CommandId + " after=" + $LaunchConfirmSeconds + "s")
  return $false
}

if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

Write-Log "LISTENER START worker=$WorkerId pid=$PID"
$state = Load-State
Ensure-StateFields $state
Save-State $state

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
              $launched = Send-Ack $commandId "launched"
              if ($launched -ne "OK") {
                Write-Log "LAUNCH ACK WARNING command=$commandId result=$launched"
              }
            } else {
              Write-Log "LAUNCH NOT CONFIRMED command=$commandId; no launched ACK"
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
