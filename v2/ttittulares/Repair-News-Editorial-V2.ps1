# Update only the News V2 editorial consumer. Allow existing chats to finish;
# do not stop the News V2 image daemon, any Chrome, Trends or V1 service.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$taskName='TTActualidadNoticiasV2-Editorial'
$flag=Join-Path $root 'editorial.enabled'
$pointer=Join-Path $root 'active-code.txt'
$runner=Join-Path $root 'Run-News-Editorial-Auto.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
if(-not (Test-Path -LiteralPath (Join-Path $root 'settings.json'))){throw 'NEWS_EDITORIAL_V2_NOT_INSTALLED'}
if(-not (Test-Path -LiteralPath $pointer)){throw 'NEWS_EDITORIAL_RELEASE_POINTER_MISSING'}
if(-not (Test-Path -LiteralPath $runner)){throw 'NEWS_EDITORIAL_LAUNCHER_MISSING'}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $task){throw 'NEWS_EDITORIAL_WINDOWS_TASK_MISSING'}
$previousTaskEnabled=($task.State -ne 'Disabled')
$previousFlag=if(Test-Path -LiteralPath $flag){(Get-Content -LiteralPath $flag -Raw).Trim()}else{'TTN2_EDITORIAL_ENABLED=NO'}
$previousCode=(Get-Content -LiteralPath $pointer -Raw).Trim()
if(-not (Test-Path -LiteralPath (Join-Path $previousCode 'v2\ttittulares\editorial_consumer_v2.py'))){throw 'NEWS_EDITORIAL_PREVIOUS_RELEASE_MISSING'}
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not (Get-Command gh.exe -ErrorAction SilentlyContinue)){
  throw 'NEWS_GITHUB_AUTH_REQUIRED: gh auth login o GH_TOKEN'
}

# Download a pinned, hash-verified release before pausing new editorial work.
$api='https://api.github.com/repos/fabricelop/europapress-rss'
$branch='feature/ttactualidad-v2-clean'
$headers=@{'User-Agent'='TTNoticiasV2-editorial-repair';'Accept'='application/vnd.github+json'}
$commit=Invoke-RestMethod -Uri ($api+'/commits/'+[Uri]::EscapeDataString($branch)) -Headers $headers
$sha=[string]$commit.sha
if($sha -notmatch '^[a-f0-9]{40}$'){throw 'NEWS_EDITORIAL_COMMIT_NOT_PINNED'}
$tree=Invoke-RestMethod -Uri ($api+'/git/trees/'+$sha+'?recursive=1') -Headers $headers
if($tree.truncated){throw 'NEWS_EDITORIAL_GIT_TREE_TRUNCATED'}
$code=Join-Path $root ('releases\'+$sha)
New-Item -ItemType Directory -Path $code -Force | Out-Null
$news=@('news_workflow_v2.py','news_images_v2.py','test_news_workflow_v2.py','test_news_images_v2.py','editorial_browser_v2.py','editorial_consumer_v2.py','editorial_contract_v2.py','session_watchdog_v2.py','test_session_watchdog_v2.py',
  'editorial_state_v2.py','editorial_setup_v2.py','test_editorial_consumer_v2.py',
  'test_editorial_state_v2.py','test_editorial_contract_v2.py','test_contract_examples.py',
  'test_radar_snapshot_v2.py','test_radar_ingest_v2.py','test_editorial_browser_v2.py','test_editorial_setup_v2.py',
  'radar_snapshot_v2.py','radar_store_v2.py','radar_ingest_v2.py','identity_v2.py',
  'source_fetch_v2.py','source_publication_v2.py','source_catalog_v2.py','source_catalog_v2.json',
  'source_health_v2.py','content_filters_v2.py','schemas/contract.schema.json','examples/sample-bundle.json')
$shared=@('chrome_command_v2.py','chrome_visibility_v2.py','chrome_profile_process_v2.py',
          'chrome_cleanup_v2.py','chrome_startup_v2.py','process_lock_v2.py','image_intake_v2.py','image_same_chat_v2.py','image_job_v2.py','image_github_v2.py')
$paths=@($news | ForEach-Object {'v2/ttittulares/'+$_})+@($shared | ForEach-Object {'v2/ttendencias/'+$_})
$paths+=@('v2/ttittulares/Run-News-Editorial-Auto.ps1')
foreach($path in $paths){
  $entry=@($tree.tree | Where-Object {$_.path -eq $path -and $_.type -eq 'blob'})
  if($entry.Count -ne 1){throw ('NEWS_EDITORIAL_MISSING_FILE='+$path)}
  $target=Join-Path $code ($path.Replace('/','\'))
  New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/'+$path) -Headers $headers -OutFile $target
  $bytes=[IO.File]::ReadAllBytes($target)
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $hash=[Security.Cryptography.SHA1]::Create()
  try{$actual=([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  if($actual -ne $entry[0].sha){throw ('NEWS_EDITORIAL_GIT_HASH_MISMATCH='+$path)}
}

$logs=Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$probeOut=Join-Path $logs 'editorial-repair-check.stdout.json'
$probeErr=Join-Path $logs 'editorial-repair-check.stderr.log'
$probe=Start-Process -FilePath $py -WorkingDirectory $code -ArgumentList @('-3','-m','v2.ttittulares.editorial_consumer_v2','--root',('"'+$root+'"'),'--check') `
  -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
if($probe.ExitCode -ne 0){
  if(Test-Path -LiteralPath $probeErr){Get-Content -LiteralPath $probeErr -Tail 12 | ForEach-Object {Write-Host $_}}
  throw ('NEWS_EDITORIAL_PREFLIGHT_FAILED='+$probe.ExitCode)
}
$check=Get-Content -LiteralPath $probeOut -Raw | ConvertFrom-Json
if($check.project -ne 'ttittulares-v2' -or $check.browser_opened -ne $false -or $null -eq $check.preview.blocking_recovery_incident_count){
  throw 'NEWS_EDITORIAL_PREFLIGHT_INCOMPLETE'
}

# Make a durable backup. The image launcher, image-active-code.txt and task
# are deliberately not touched, even when the image consumer is working.
$backup=Join-Path $root ('Backup-Editorial-Repair-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $runner -Destination (Join-Path $backup 'Run-News-Editorial-Auto.ps1')
Copy-Item -LiteralPath $pointer -Destination (Join-Path $backup 'active-code.txt')
$switched=$false
try{
  Disable-ScheduledTask -TaskName $taskName | Out-Null
  [IO.File]::WriteAllText($flag,'TTN2_EDITORIAL_ENABLED=NO',$utf8)
  $until=(Get-Date).AddMinutes(25)
  do{
    $active=@(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -match '^(python|pythonw|py)\.exe$' -and
      [string]$_.CommandLine -match 'v2\.ttittulares\.editorial_consumer_v2'
    })
    if(-not $active.Count){break}
    if((Get-Date) -gt $until){throw 'NEWS_EDITORIAL_WORKERS_STILL_ACTIVE: los chats siguen cerrándose; no se fuerza Chrome'}
    Write-Host ('TTN2_EDITORIAL_DRAIN_WAIT='+$active.Count)
    Start-Sleep -Seconds 10
  }while($true)

  $switched=$true
  Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Run-News-Editorial-Auto.ps1') -Destination $runner -Force
  [IO.File]::WriteAllText($pointer,$code,$utf8)
  Write-Host ('TTN2_EDITORIAL_RELEASE='+$sha)
  Write-Host ('TTN2_EDITORIAL_BACKUP='+$backup)
  Write-Host ('TTN2_EDITORIAL_RECOVERY_ISOLATED='+$check.preview.blocking_recovery_incident_count)
}catch{
  # No new daemon can start until restoration completes.
  if($switched){
    Copy-Item -LiteralPath (Join-Path $backup 'Run-News-Editorial-Auto.ps1') -Destination $runner -Force
    [IO.File]::WriteAllText($pointer,$previousCode,$utf8)
  }
  throw
}finally{
  [IO.File]::WriteAllText($flag,$previousFlag,$utf8)
  if($previousTaskEnabled){
    Enable-ScheduledTask -TaskName $taskName | Out-Null
    if($previousFlag -eq 'TTN2_EDITORIAL_ENABLED=YES'){
      Start-ScheduledTask -TaskName $taskName
      Write-Host 'TTN2_EDITORIAL_WORKERS_START_REQUESTED=YES'
    }
  }
}
Write-Host 'TTN2_IMAGE_WINDOWS_TASK_UNCHANGED=YES'
Write-Host ('TTN2_EDITORIAL_LOGS='+ $logs)
