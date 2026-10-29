#requires -Version 5.1
# Read-only TTActualidad editorial diagnosis. Does not start/stop tasks, Chrome or listeners.
$ErrorActionPreference = "Continue"
$base = "C:\TTiTTulares"
function Redact([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+','$1[REDACTED]'
  $s = $s -replace '(?i)(github_pat_|ghp_|gho_|ghu_)[A-Za-z0-9_]+','[REDACTED_TOKEN]'
  $s = $s -replace '(?i)(TT_CHAT_MESSAGE_B64\s*[:=]\s*)\S+','$1[REDACTED]'
  return $s
}
Write-Output "TT_EDITORIAL_LOCAL_DIAG_V1"
Write-Output ("LOCAL_TIME: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Output "===== SCHEDULED TASKS (Ready is NOT editorial success) ====="
foreach ($name in @("TTiTTulares Local","TTendencias Local","TTendencias Local Ready","TT Chrome Auto")) {
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $task) { Write-Output "TASK $name : NOT_FOUND"; continue }
  $info=Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
  Write-Output ("TASK {0} | State={1} | Last={2} | Result={3} | Next={4}" -f $name,$task.State,$info.LastRunTime,$info.LastTaskResult,$info.NextRunTime)
  foreach ($action in @($task.Actions)) {
    $exe=[string]$action.Execute
    $args=[string]$action.Arguments
    if ($args -match '(?i)token|password|secret|authorization|api.key') { $args="[ARGUMENTS_REDACTED]" }
    Write-Output ("  ACTION Exe={0} Args={1} WorkingDir={2}" -f (Redact $exe),(Redact $args),(Redact ([string]$action.WorkingDirectory)))
  }
}
Write-Output "===== DEDICATED EDITORIAL LISTENERS ====="
$all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($marker in @("TTiTTularesDedicatedListener.ps1","TTendenciasDedicatedListener.ps1","TT-LocalWatchdog.ps1")) {
  $found=@($all | Where-Object { [string]$_.CommandLine -like "*$marker*" })
  Write-Output ("PROCESS {0} | count={1} | pids={2}" -f $marker,$found.Count,(($found | ForEach-Object { $_.ProcessId }) -join ","))
}
foreach ($name in @("Ejecutar.js","TTiTTularesDedicatedListener.ps1","TTendenciasDedicatedListener.ps1")) {
  $p=Join-Path $base $name
  if (Test-Path -LiteralPath $p) {
    $file=Get-Item -LiteralPath $p
    Write-Output ("FILE {0} | present | updated={1}" -f $name,$file.LastWriteTime)
  } else { Write-Output "FILE $name | MISSING" }
}
$node=Get-Command node.exe -ErrorAction SilentlyContinue
Write-Output ("NODE: " + $(if($node){$node.Source}else{"NOT_FOUND"}))
try {
  $cdp=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -TimeoutSec 3
  Write-Output ("CHROME_CDP_9223: OK " + [string]$cdp.Browser)
} catch { Write-Output "CHROME_CDP_9223: UNAVAILABLE" }

Write-Output "===== LOCAL STATE (NOT a success receipt) ====="
foreach ($name in @("ttittulares-mobile-trigger-state.json","ttendencias-mobile-trigger-state.json")) {
  $p=Join-Path $base $name
  if (-not (Test-Path -LiteralPath $p)) { Write-Output "STATE $name | MISSING";continue }
  try {
    $d=Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("STATE {0} | last_command_id={1} | retry_command_id={2} | retry_after={3}" -f $name,$d.last_command_id,$d.editorial_retry_command_id,$d.editorial_retry_after)
  } catch { Write-Output "STATE $name | INVALID_JSON" }
}
Write-Output "===== DEDICATED LISTENER LOGS (recent editorial evidence) ====="
foreach ($name in @("ttittulares-mobile-trigger.log","ttendencias-mobile-trigger.log")) {
  $p=Join-Path $base $name
  if (-not (Test-Path -LiteralPath $p)) { Write-Output "LOG $name | MISSING";continue }
  $fi=Get-Item $p
  Write-Output ("LOG {0} | updated={1}" -f $name,$fi.LastWriteTime)
  Get-Content -LiteralPath $p -Tail 350 -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '(?i)TRIGGER PROBE|EDITORIAL PROCESS|EDITORIAL LOOP|EDITORIAL RETRY|EDITORIAL JOB|CHAT MESSAGE|CHAT LAUNCH|CHAT PROCESS|LAUNCH CONFIRMED|LAUNCH FAILED|ACK (picked_up|launched|ERROR|CONFLICT)|ERROR|HEARTBEAT' } |
    Select-Object -Last 22 | ForEach-Object { Write-Output ("  "+(Redact ([string]$_))) }
}
Write-Output "===== LAST LAUNCH ERRORS ====="
foreach ($prefix in @("ttittulares-launch-","ttendencias-launch-")) {
  $list=@(Get-ChildItem -Path $base -Filter ($prefix+"*.err.log") -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 2)
  if (-not $list) { Write-Output ("LAUNCH "+$prefix+" none"); continue }
  foreach ($f in $list) {
    Write-Output ("LAUNCH {0} updated={1} bytes={2}" -f $f.Name,$f.LastWriteTime,$f.Length)
    Get-Content -LiteralPath $f.FullName -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("  "+(Redact ([string]$_))) }
  }
}
Write-Output "TT_EDITORIAL_LOCAL_DIAG_END (read-only, no changes made)"
