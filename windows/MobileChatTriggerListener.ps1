# MobileChatTriggerListener.ps1
# Móvil -> GitHub trigger -> PC -> ChatGPT project chat.
# Reutiliza C:\TTiTTulares\LanzarOculto.vbs:
#   titulares  -> "Ejecuta TTiTTulares"
#   tendencias -> "Ejecuta TTendencias"

$ErrorActionPreference = "Continue"
$BaseDir = "C:\TTiTTulares"
$Launcher = Join-Path $BaseDir "LanzarOculto.vbs"
$StatePath = Join-Path $BaseDir "mobile-trigger-state.json"
$LogPath = Join-Path $BaseDir "mobile-trigger.log"
$PollSeconds = 4
$RunTimeoutMinutes = 35
$StatusBase = "https://europapress-rss.vercel.app"

$Targets = [ordered]@{
  ttittulares = @{
    TriggerUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttittulares-run-trigger-v2/ttittulares/run-now-trigger.json"
    RunStatusUrl = "$StatusBase/api/ttittulares-run-status"
    LauncherArg = "titulares"
  }
  ttendencias = @{
    TriggerUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/run-now-trigger.json"
    RunStatusUrl = "$StatusBase/api/ttendencias-run-status"
    LauncherArg = "tendencias"
  }
}

function Write-Log([string]$Text) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Read-JsonUrl([string]$Url) {
  try {
    return Invoke-RestMethod -Uri ($Url + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 12
  } catch {
    Write-Log "HTTP ERROR $Url :: $($_.Exception.Message)"
    return $null
  }
}

function Save-State($State) {
  $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Load-State {
  if (Test-Path -LiteralPath $StatePath) {
    try { return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return $null
}

function New-StateObject {
  [pscustomobject]@{
    initialized_at = (Get-Date).ToString("o")
    ttittulares = [pscustomobject]@{ last_command_id = ""; followup_for = "" }
    ttendencias = [pscustomobject]@{ last_command_id = ""; followup_for = "" }
  }
}

function Ensure-State {
  $state = Load-State
  if ($state) { return $state }

  # Baseline: no reejecutar triggers antiguos al instalar.
  $state = New-StateObject
  foreach ($name in $Targets.Keys) {
    $doc = Read-JsonUrl $Targets[$name].TriggerUrl
    if ($doc -and $doc.command_id) {
      $state.$name.last_command_id = [string]$doc.command_id
    }
  }
  Save-State $state
  Write-Log "INITIALIZED baseline without replaying old triggers"
  return $state
}

function Invoke-ProjectChat([string]$LauncherArg, [string]$Reason) {
  if (-not (Test-Path -LiteralPath $Launcher)) {
    throw "No existe $Launcher"
  }
  Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList @($Launcher,$LauncherArg) -WindowStyle Hidden | Out-Null
  Write-Log "LAUNCHED $LauncherArg :: $Reason"
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
    $s = Read-JsonUrl $StatusUrl
    if (-not $s) { continue }

    if ($s.active) {
      $startMs = Get-RunStartMs $s
      if ($startMs -ge ($requestedMs - 30000)) { $seen = $true }
      continue
    }

    $last = $s.last_run
    if ($last) {
      $startMs = Get-RunStartMs $last
      if ($startMs -ge ($requestedMs - 30000)) {
        return $last
      }
    }
    if ($seen -and -not $s.active) {
      return $last
    }
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

if (-not (Test-Path -LiteralPath $BaseDir)) {
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}

Write-Log "LISTENER START"
$state = Ensure-State

while ($true) {
  foreach ($name in $Targets.Keys) {
    try {
      $target = $Targets[$name]
      $doc = Read-JsonUrl $target.TriggerUrl
      if (-not $doc -or -not $doc.command_id) { continue }
      if ([string]$doc.executor -ne "pc_chat") { continue }

      $commandId = [string]$doc.command_id
      if ($commandId -eq [string]$state.$name.last_command_id) { continue }

      $state.$name.last_command_id = $commandId
      $state.$name.followup_for = ""
      Save-State $state

      try { $requestedAt = [DateTimeOffset]::Parse([string]$doc.requested_at) } catch { $requestedAt = [DateTimeOffset]::UtcNow }
      Invoke-ProjectChat $target.LauncherArg "mobile command $commandId"

      if ($doc.auto_image_followup -eq $true) {
        $lastRun = Wait-ForCompletedRun $target.RunStatusUrl $requestedAt
        $backlog = Visual-Backlog $lastRun
        Write-Log "PRIMARY DONE $name command=$commandId visual_backlog=$backlog"

        if ($backlog -gt 0 -and [string]$state.$name.followup_for -ne $commandId) {
          Start-Sleep -Seconds 5
          Invoke-ProjectChat $target.LauncherArg "automatic image follow-up for $commandId ($backlog pending)"
          $state.$name.followup_for = $commandId
          Save-State $state
        }
      }
    } catch {
      Write-Log "ERROR $name :: $($_.Exception.Message)"
    }
  }
  Start-Sleep -Seconds $PollSeconds
}
