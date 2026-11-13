# TTActualidad V2 - diagnóstico seguro del primer ciclo automático.
# SÓLO lectura: no reinicia tarea, no envía prompts, no cierra Chrome.
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName = 'TTActualidadV2-Editorial-Auto'
$trend = 'trv2-e94b2984c087ac403753b8c1'
Write-Host 'TT_V2_DIAG_BEGIN'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
  Write-Host ('TT_V2_TASK_STATE=' + $task.State)
  $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
  if ($info) {
    Write-Host ('TT_V2_TASK_LAST_RESULT=' + $info.LastTaskResult)
    Write-Host ('TT_V2_TASK_LAST_RUN=' + $info.LastRunTime.ToString('o'))
  }
} else { Write-Host 'TT_V2_TASK_STATE=NOT_FOUND' }
$flag = Join-Path $root 'auto-editorial-v2.enabled'
if (Test-Path $flag) {
  $value = (Get-Content -LiteralPath $flag -Raw -ErrorAction SilentlyContinue).Trim()
  Write-Host ('TT_V2_AUTO_ENABLED=' + [bool]($value -eq 'TT_V2_AUTO_EDITORIAL_ENABLED=YES'))
}
$daemon = Join-Path $root 'daemon-status.json'
if (Test-Path $daemon) {
  try {
    $state = Get-Content $daemon -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('TT_V2_DAEMON_STATE=' + $state.state)
    Write-Host ('TT_V2_DAEMON_AT=' + $state.at)
    Write-Host ('TT_V2_DAEMON_COMPLETED=' + $state.completed)
    if ($state.last_error) { Write-Host ('TT_V2_DAEMON_ERROR=' + $state.last_error) }
  } catch { Write-Host 'TT_V2_DAEMON_STATE=READ_ERROR' }
} else { Write-Host 'TT_V2_DAEMON_STATE=NO_FILE' }
$journal = Join-Path $root ('diagnostics\run-' + $trend + '-r1.json')
if (Test-Path $journal) {
  try {
    $j = Get-Content $journal -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('TT_V2_JOURNAL_STATUS=' + $j.status)
    Write-Host ('TT_V2_JOURNAL_MESSAGE_SENT=' + $j.message_sent)
    Write-Host ('TT_V2_JOURNAL_REPLY_CAPTURED=' + $j.reply_captured)
    Write-Host ('TT_V2_JOURNAL_CLEANUP_VERIFIED=' + $j.cleanup_verified)
    Write-Host ('TT_V2_JOURNAL_PERSISTED=' + $j.persisted)
    Write-Host ('TT_V2_JOURNAL_CHAT_FOUND=' + [bool]$j.chat_url)
    Write-Host ('TT_V2_JOURNAL_CHAT_DISCOVERY=' + $j.chat_discovery.status)
    Write-Host ('TT_V2_JOURNAL_CAPTURE_REASON=' + $j.capture_diagnostic.reason)
    if ($j.error) { Write-Host ('TT_V2_JOURNAL_ERROR=' + $j.error) }
  } catch { Write-Host 'TT_V2_JOURNAL_STATUS=READ_ERROR' }
} else { Write-Host 'TT_V2_JOURNAL_STATUS=NO_FILE' }
try {
  $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $editors = @($processes | Where-Object {($_.Name -like 'python*' -or $_.Name -like 'py.exe') -and
          $_.CommandLine -like '*editorial_daemon_v2.py*'})
  $chromes = @($processes | Where-Object { $_.Name -ieq 'chrome.exe' -and
          $_.CommandLine -like '*TTActualidadV2*ChromeProfile*' })
  Write-Host ('TT_V2_DAEMON_PROCESS_COUNT=' + $editors.Count)
  Write-Host ('TT_V2_CHROME_PROCESS_COUNT=' + $chromes.Count)
  if ($chromes.Count) { Write-Host ('TT_V2_CHROME_PIDS=' + (($chromes | ForEach-Object {$_.ProcessId}) -join ',')) }
} catch { Write-Host 'TT_V2_PROCESS_SCAN=FAILED' }
$logDir = Join-Path $root 'editorial-auto-logs'
$latest = Get-ChildItem -LiteralPath $logDir -Filter 'auto-*.log' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
  Write-Host ('TT_V2_LOG=' + $latest.Name)
  Write-Host 'TT_V2_LOG_TAIL_BEGIN'
  Get-Content -LiteralPath $latest.FullName -Tail 24 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host $_ }
  Write-Host 'TT_V2_LOG_TAIL_END'
} else { Write-Host 'TT_V2_LOG=NOT_FOUND' }
Write-Host 'TT_V2_DIAG_READ_ONLY=YES'
