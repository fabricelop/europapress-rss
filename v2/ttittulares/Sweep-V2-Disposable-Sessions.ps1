# Safely list or remove abandoned disposable V2 browser profiles.
# Defaults to read-only. Does not stop browsers or workers; never touches seeds.
[CmdletBinding()]
param([switch]$Apply, [ValidateRange(20, 10080)][int]$MinAgeMinutes = 30)
$ErrorActionPreference = 'Stop'

$now = Get-Date
$cutoff = $now.AddMinutes(-$MinAgeMinutes)
$newsRoot = Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$trendsRoot = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$processes = @(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -match '^(chrome|python|pythonw|py)\.exe$'
})

function Test-ProcessMentions([string]$value) {
  return [bool]@($processes | Where-Object {
    [string]$_.CommandLine -and
    $_.CommandLine.IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -ge 0
  }).Count
}

function Test-OldWorkerWithoutRunId([string]$module) {
  return [bool]@($processes | Where-Object {
    [string]$_.CommandLine -match $module -and
    [string]$_.CommandLine -notmatch '--run-id\s+[a-f0-9]{32}'
  }).Count
}

$candidates = [Collections.Generic.List[object]]::new()
$excluded = [Collections.Generic.List[object]]::new()
function Inspect-Folder([IO.DirectoryInfo]$folder, [string]$type, [string]$journalPath) {
  $reason = ''
  if (($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $reason = 'REPARSE_POINT' }
  elseif ($folder.LastWriteTime -gt $cutoff) { $reason = 'TOO_RECENT' }
  elseif (Test-ProcessMentions $folder.FullName) { $reason = 'ACTIVE_CHROME_OR_WORKER' }
  elseif ($type -eq 'news-editorial' -and (Test-OldWorkerWithoutRunId 'v2\.ttittulares\.editorial_consumer_v2')) { $reason = 'LEGACY_WORKER_ACTIVE' }
  elseif ($type -eq 'news-image' -and (Test-OldWorkerWithoutRunId 'v2\.ttittulares\.news_images_v2')) { $reason = 'LEGACY_WORKER_ACTIVE' }
  elseif ($type -eq 'trend-editorial' -and (Test-ProcessMentions 'editorial_run_v2.py')) { $reason = 'TREND_EDITORIAL_ACTIVE' }
  elseif ($type -eq 'trend-image' -and (Test-ProcessMentions 'image_worker_v2.py')) { $reason = 'TREND_IMAGE_ACTIVE' }
  elseif ($journalPath -and -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { $reason = 'JOURNAL_MISSING' }
  if ($reason) {
    $excluded.Add([pscustomobject]@{Type=$type;Folder=$folder.FullName;Reason=$reason})
    return
  }
  $bytes = (Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -Force -ErrorAction Stop |
    Measure-Object -Property Length -Sum).Sum
  $candidates.Add([pscustomobject]@{Type=$type;Folder=$folder.FullName;Bytes=[long]$bytes})
}

foreach ($kind in @('sessions', 'image-sessions')) {
  $base = Join-Path $newsRoot $kind
  if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
  $type = if($kind -eq 'sessions'){'news-editorial'}else{'news-image'}
  $journalDir = if($kind -eq 'sessions'){'journals'}else{'image-journals'}
  foreach ($folder in (Get-ChildItem -LiteralPath $base -Directory -Force)) {
    if ($folder.Name -notmatch '^[a-f0-9]{32}$') { continue }
    $journal = Join-Path (Join-Path $newsRoot $journalDir) ($folder.Name + '.json')
    Inspect-Folder $folder $type $journal
  }
}

foreach ($kind in @('editorial', 'image')) {
  if (-not (Test-Path -LiteralPath $trendsRoot -PathType Container)) { break }
  $prefix = if($kind -eq 'editorial'){'ChromeProfile-Job-'}else{'ChromeProfileImages-Job-'}
  foreach ($folder in (Get-ChildItem -LiteralPath $trendsRoot -Directory -Force)) {
    if (-not $folder.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $folder.Name -notmatch '-Job-\d\d$') { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName 'tt-v2-ephemeral-owned.marker') -PathType Leaf)) {
      continue
    }
    Inspect-Folder $folder ('trend-' + $kind) ''
  }
}

$total = [long](($candidates | Measure-Object -Property Bytes -Sum).Sum)
Write-Output ('TT_V2_SWEEP_MODE=' + $(if($Apply){'APPLY'}else{'DRY_RUN'}))
Write-Output ('TT_V2_SWEEP_CANDIDATES=' + $candidates.Count)
Write-Output ('TT_V2_SWEEP_CANDIDATE_GIB=' + [Math]::Round($total / 1GB, 2))
Write-Output ('TT_V2_SWEEP_EXCLUDED=' + $excluded.Count)
foreach ($item in $candidates) {
  Write-Output ('CANDIDATE ' + $item.Type + ' ' + [Math]::Round($item.Bytes / 1GB, 2) + ' GiB ' + $item.Folder)
}
if ($Apply) {
  $deleted = 0
  foreach ($item in $candidates) {
    # Recheck exact Chrome/Python ownership immediately before each deletion.
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -match '^(chrome|python|pythonw|py)\.exe$'
    })
    if (Test-ProcessMentions $item.Folder) { continue }
    if ($item.Type -eq 'news-editorial' -and (Test-OldWorkerWithoutRunId 'v2\.ttittulares\.editorial_consumer_v2')) { continue }
    if ($item.Type -eq 'news-image' -and (Test-OldWorkerWithoutRunId 'v2\.ttittulares\.news_images_v2')) { continue }
    if ($item.Type -eq 'trend-editorial' -and (Test-ProcessMentions 'editorial_run_v2.py')) { continue }
    if ($item.Type -eq 'trend-image' -and (Test-ProcessMentions 'image_worker_v2.py')) { continue }
    $folder = Get-Item -LiteralPath $item.Folder -Force
    if ($folder.LastWriteTime -gt $cutoff -or
        ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    Remove-Item -LiteralPath $item.Folder -Recurse -Force -ErrorAction Stop
    $deleted++
  }
  Write-Output ('TT_V2_SWEEP_DELETED=' + $deleted)
}
