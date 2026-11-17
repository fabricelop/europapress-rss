# Read-only health and targeted disk audit. Never opens Chrome or changes tasks.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$trendRoot = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'

Write-Output 'TTN2_HEALTH_MODE=READ_ONLY'
foreach ($name in @('TTActualidadNoticiasV2-Editorial','TTActualidadNoticiasV2-Images')) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  Write-Output ('TASK '+$name+' '+$(if($task){$task.State}else{'MISSING'}))
}
foreach ($pointer in @('active-code.txt','image-active-code.txt')) {
  $file = Join-Path $root $pointer
  $kind = if($pointer -eq 'active-code.txt'){'EDITORIAL'}else{'IMAGE'}
  $code = if(Test-Path -LiteralPath $file -PathType Leaf){
    [string](Get-Content -LiteralPath $file -Raw).Trim()
  }else{''}
  $consumer = if($kind -eq 'EDITORIAL'){'editorial_consumer_v2.py'}else{'news_images_v2.py'}
  $installed = $code -and (Test-Path -LiteralPath (Join-Path $code ('v2\ttittulares\'+$consumer)) -PathType Leaf)
  $watchdog = $code -and (Test-Path -LiteralPath (Join-Path $code 'v2\ttittulares\session_watchdog_v2.py') -PathType Leaf)
  Write-Output ('NEWS_'+$kind+'_INSTALLED='+[bool]$installed)
  Write-Output ('NEWS_'+$kind+'_WATCHDOG_PRESENT='+[bool]$watchdog)
  if($code){Write-Output ('NEWS_'+$kind+'_RELEASE='+ (Split-Path -Leaf $code))}
}

function Folder-Bytes([string]$path) {
  if(-not (Test-Path -LiteralPath $path -PathType Container)){return [long]0}
  $files = Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue
  return [long](($files | Measure-Object -Property Length -Sum).Sum)
}
foreach ($name in @('sessions','image-sessions','AuthSeed','image-originals','logs','image-logs')) {
  $path = Join-Path $root $name
  $count = if($name -in @('sessions','image-sessions') -and (Test-Path -LiteralPath $path -PathType Container)){
    @(Get-ChildItem -LiteralPath $path -Directory -Force).Count
  }else{0}
  Write-Output ('NEWS_DISK '+$name+' folders='+$count+' MiB='+[Math]::Round((Folder-Bytes $path)/1MB,1))
}

$imageJournals = Join-Path $root 'image-journals'
$saved=0;$clean=0;$pending=0
if(Test-Path -LiteralPath $imageJournals -PathType Container){
  foreach($file in (Get-ChildItem -LiteralPath $imageJournals -Filter '*.json' -File -Force)){
    try{
      $j = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      if($j.saved -eq $true){$saved++}
      if($j.cleanup_verified -eq $true){$clean++}
      if($j.sent -eq $true -and $j.saved -ne $true){$pending++}
    }catch{} # Never print private journal contents, URLs or lease tokens.
  }
}
Write-Output ('NEWS_IMAGE_JOURNALS_SAVED='+$saved)
Write-Output ('NEWS_IMAGE_JOURNALS_CLEANUP_VERIFIED='+$clean)
Write-Output ('NEWS_IMAGE_JOURNALS_SENT_NOT_SAVED='+$pending)

foreach($name in @('editorial-reclaim-status.json','image-daemon-status.json')){
  $path=Join-Path $root $name
  if(Test-Path -LiteralPath $path -PathType Leaf){
    try{
      $j=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      if($name -eq 'editorial-reclaim-status.json'){
        Write-Output ('NEWS_EDITORIAL_RECLAIM='+$j.reclaimed+' ERROR='+$j.error_code)
      }else{
        Write-Output ('NEWS_IMAGE_WORKERS='+$j.workers_running+' ERROR='+$j.error_code)
        if($j.profile_reclaim){Write-Output ('NEWS_IMAGE_RECLAIM='+$j.profile_reclaim.reclaimed+' ERROR='+$j.profile_reclaim.error_code)}
      }
    }catch{Write-Output ('NEWS_HEALTH_FILE_UNREADABLE='+$name)}
  }
}
foreach($kind in @('EDITORIAL','IMAGE')){
  $prefix=if($kind -eq 'EDITORIAL'){'ChromeProfile-Job-*'}else{'ChromeProfileImages-Job-*'}
  $trends=@()
  if(Test-Path -LiteralPath $trendRoot -PathType Container){
    $trends=@(Get-ChildItem -LiteralPath $trendRoot -Directory -Force | Where-Object {
      $_.Name -like $prefix -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'tt-v2-ephemeral-owned.marker') -PathType Leaf)
    })
  }
  $bytes=[long]0
  foreach($folder in $trends){$bytes+=(Folder-Bytes $folder.FullName)}
  Write-Output ('TENDENCIAS_'+$kind+'_DISPOSABLE_PROFILES='+$trends.Count+' MiB='+[Math]::Round($bytes/1MB,1))
}
Write-Output ('TENDENCIAS_IMAGE_ORIGINALS_MIB='+[Math]::Round((Folder-Bytes (Join-Path $trendRoot 'image-originals'))/1MB,1))
Write-Output 'TTN2_HEALTH_COMPLETED=YES'
