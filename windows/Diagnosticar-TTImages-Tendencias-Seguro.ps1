#requires -Version 5.1
<#
TTImages - diagnostic read-only for Trends vs News and the independent relay.
Does NOT start/stop/restart Chrome, processes, jobs, scheduled tasks or ImageGen.
Does NOT read or print tokens, private URLs, editorial texts or image bytes.
Run as the Windows user who owns TTImages.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
$root='C:\TTiTTulares'
$relay=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
function Say([string]$label,[string]$value=''){
  $safe=([string]$value -replace '(?i)https?://\S+','[url]')
  $safe=$safe -replace '[^\x20-\x7E]','_'
  if($safe.Length -gt 170){$safe=$safe.Substring(0,170)}
  Write-Host ('TTIMAGES_DIAG '+$label+' '+$safe)
}
function ReadJson([string]$p){
  if(-not(Test-Path -LiteralPath $p)){return $null}
  try{return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)}
  catch{return $null}
}
function Timestamp([object]$v){
  $s=[string]$v
  if($s -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d'){return $s.Substring(0,19)}
  return ''
}
function ProbeChrome([int]$port){
  $b='http://127.0.0.1:'+$port
  try {
    $ver=Invoke-RestMethod -Uri ($b+'/json/version') -TimeoutSec 5 -ErrorAction Stop
    $raw=Invoke-WebRequest -UseBasicParsing -Uri ($b+'/json/list') -TimeoutSec 5 -ErrorAction Stop
    $targets=@(ConvertFrom-Json -InputObject ([string]$raw.Content) -ErrorAction Stop)
    $pages=@($targets|Where-Object {[string]$_.type -eq 'page'})
    $chat=@($pages|Where-Object {[string]$_.url -match '^https://chatgpt[.]com/'})
    $gallery=@($chat|Where-Object {[string]$_.url -match '^https://chatgpt[.]com/images(?:/|[?#]|$)'})
    $valid=([string]$ver.Browser -match '^Chrome/')
    Say ('CDP'+$port) $(if($valid){'UP'}else{'UNKNOWN_BROWSER'})
    Say ('CDP'+$port+'_PAGES') ('all='+$pages.Count+' chat='+$chat.Count+' galleries='+$gallery.Count)
  } catch {Say ('CDP'+$port) 'DOWN_OR_UNREACHABLE'}
}
function InspectLock([string]$name,[string]$filename,[string]$expectedProcess){
  $doc=ReadJson (Join-Path $root $filename)
  if(-not $doc){Say $name 'NO_LOCK_OR_UNREADABLE';return}
  $id=0;try{$id=[int]$doc.pid}catch{}
  if($id -le 0){Say $name 'INVALID_PID';return}
  $alive=Get-Process -Id $id -ErrorAction SilentlyContinue
  if(-not $alive){Say $name 'STALE_PID_NOT_RUNNING';return}
  $cmd=$null
  try{$cmd=Get-CimInstance Win32_Process -Filter ('ProcessId='+$id) -ErrorAction Stop}catch{}
  $correct=([string]$cmd.CommandLine -like ('*'+$expectedProcess+'*'))
  $age=-1
  try{$age=[Math]::Round(([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$doc.started_at)).TotalMinutes,1)}catch{}
  Say $name ('pid='+$id+' '+$(if($correct){'OWN_BRIDGE_RUNNING'}elseif($cmd){'PID_NOT_OWN_BRIDGE'}else{'PROCESS_UNVERIFIED'})+' age_min='+$age)
}
function InspectTask([string]$name,[string]$tag){
  try{
    $task=Get-ScheduledTask -TaskName $name -ErrorAction Stop
    $info=Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop
    Say ('TASK_'+$tag) ('state='+[string]$task.State+' last_result='+[string]$info.LastTaskResult+' last_run='+[string]$info.LastRunTime.ToString('yyyy-MM-ddTHH:mm:ss'))
  }catch{Say ('TASK_'+$tag) 'MISSING_OR_UNREADABLE'}
}
function ReadPublic([string]$path,[string]$branch){
  $uri='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$branch+'/'+$path
  try{
    return Invoke-RestMethod -Method Get -Uri ($uri+'?diagnostic='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 10 -Headers @{'Cache-Control'='no-cache';'User-Agent'='TTImages-ReadOnly-Trends-News'} -ErrorAction Stop
  }catch{return $null}
}
function InspectImageIndex([string]$name,[string]$path,[string]$ref){
  $j=ReadPublic $path $ref
  if(-not $j){Say $name 'UNREACHABLE';return}
  $jobs=@($j.jobs)
  $jobs=@($jobs|Where-Object {$_ -ne $null})
  Say $name ('count='+$jobs.Count+' updated='+[string](Timestamp $j.updated_at))
  $states=@{}
  foreach($job in $jobs){
    $status=([string]$job.status).ToUpperInvariant()
    if($status -notmatch '^[A-Z_]{1,32}$'){$status='UNKNOWN'}
    if(-not $states.ContainsKey($status)){$states[$status]=0}
    $states[$status]++
  }
  foreach($k in @($states.Keys|Sort-Object)){Say ($name+'_STATUS') ($k+'='+$states[$k])}
}
function InspectEditorial(){
  $j=ReadPublic 'trends/editorial-queue.json' 'main'
  if(-not $j){Say 'TRENDS_EDITORIAL' 'UNREACHABLE';return}
  $items=@($j.items|Where-Object {$_ -ne $null})
  $pending=@($items|Where-Object {[string]$_.status -match '^(preparing|update|PROCESSING|UPDATE_PROCESSING)$'})
  $wants=@($pending|Where-Object {$_.with_image -eq $true -or $_.rewrite_with_image -eq $true})
  $first=@($pending|Sort-Object requested_at|Select-Object -First 1)
  Say 'TRENDS_EDITORIAL' ('count='+$items.Count+' pending='+$pending.Count+' wants_image='+$wants.Count+' oldest='+$(if($first.Count){Timestamp $first[0].requested_at}else{'none'}))
}
function InspectRelay(){
  Say 'RELAY_DIRECTORY' $(if(Test-Path -LiteralPath $relay){'PRESENT'}else{'MISSING'})
  $report=ReadJson (Join-Path $relay 'informe-captura-v2.json')
  if($report){
    $r=Get-Item -LiteralPath (Join-Path $relay 'informe-captura-v2.json') -ErrorAction SilentlyContinue
    $old=-1;if($r){$old=[Math]::Round(((Get-Date)-$r.LastWriteTime).TotalMinutes,1)}
    $ok=($report.error -eq $null -or [string]$report.error -eq '')
    $errorType=if($ok){'NONE'}elseif([string]$report.error -match 'Visor ya abierto'){ 'VIEWER_ALREADY_OPEN'}elseif([string]$report.error -match 'exactamente una pesta'){ 'GALLERY_TAB_MISMATCH'}else{'OTHER_ERROR'}
    Say 'RELAY_CAPTURE_REPORT' ('age_min='+$old+' error_type='+$errorType)
    foreach($field in @('guardados','saved','duplicados','duplicates')){
      if($null -ne $report.$field){Say ('RELAY_'+$field.ToUpper()) ([string]$report.$field)}
    }
  }else{Say 'RELAY_CAPTURE_REPORT' 'MISSING_OR_UNREADABLE'}
}
function InspectLogs([string]$name,[string]$file){
  if(-not(Test-Path -LiteralPath $file)){Say $name 'NO_LOG';return}
  $item=Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
  $age=-1;if($item){$age=[Math]::Round(((Get-Date)-$item.LastWriteTime).TotalMinutes,1)}
  $lines=@(Get-Content -LiteralPath $file -Tail 250 -Encoding UTF8 -ErrorAction SilentlyContinue)
  $bridge=@($lines|Where-Object{$_ -match 'IMAGE NEW |IMAGE GLOBAL SLOT WAIT|IMAGE BRIDGE STARTED|IMAGE CHROME PREFLIGHT|IMAGE OTHER LOCK STALE|IMAGE LOCAL LOCK ACTIVE|IMAGE PICKUP RETRYABLE'})
  $last=if($bridge.Count){[string]$bridge[-1]}else{''}
  $event=if($last -match 'IMAGE GLOBAL SLOT WAIT'){'WAIT_OTHER_BRIDGE'}elseif($last -match 'IMAGE NEW'){'NEW_JOB'}elseif($last -match 'IMAGE BRIDGE STARTED'){'BRIDGE_STARTED'}elseif($last -match 'IMAGE CHROME PREFLIGHT'){'CHROME_PREFLIGHT'}elseif($last -match 'IMAGE OTHER LOCK STALE'){'OTHER_STALE_LOCK'}elseif($last -match 'IMAGE LOCAL LOCK ACTIVE'){'LOCAL_BRIDGE_ACTIVE'}elseif($last -match 'IMAGE PICKUP RETRYABLE'){'PICKUP_RETRY'}else{'NO_IMAGE_EVENT'}
  Say $name ('log_age_min='+$age+' image_event_count_tail250='+$bridge.Count+' last_event='+$event)
}
Say 'START' 'READ_ONLY_V1'
ProbeChrome 9223
ProbeChrome 9234
InspectLock 'TRENDS_BRIDGE' 'ttendencias-image-bridge.lock.json' 'TTendenciasImageBridge.js'
InspectLock 'NEWS_BRIDGE' 'ttittulares-image-bridge.lock.json' 'TTiTTularesImageBridge.js'
InspectTask 'TT Image Relay - Telegram v2' 'RELAY_CAPTURE'
InspectTask 'TTImages - AutoRecovery Viewer' 'RELAY_AUTORECOVERY'
InspectTask 'TTendencias Local' 'TRENDS_LISTENER'
InspectTask 'TTiTTulares Local' 'NEWS_LISTENER'
InspectRelay
InspectLogs 'TRENDS_LISTENER_LOG' (Join-Path $root 'ttendencias-mobile-trigger.log')
InspectLogs 'NEWS_LISTENER_LOG' (Join-Path $root 'ttittulares-mobile-trigger.log')
InspectImageIndex 'TRENDS_IMAGE_QUEUE' 'trends/image-runs/index.json' 'control/ttendencias-run-trigger'
InspectImageIndex 'NEWS_IMAGE_QUEUE' 'ttittulares/image-runs/index.json' 'control/ttittulares-run-trigger-v2'
InspectEditorial
Say 'END' 'NO_CHANGES_NO_RESTART_NO_IMAGEGEN'
