# Update/restart only the Windows News V2 image consumer. The editorial
# consumer, V1, Trends, SeLoRecordamos and personal Chrome stay untouched.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$taskName='TTActualidadNoticiasV2-Images'
$flag=Join-Path $root 'images.enabled'
$utf8=New-Object Text.UTF8Encoding($false)
if(-not (Test-Path -LiteralPath (Join-Path $root 'settings.json'))){throw 'NEWS_IMAGES_V2_NOT_INSTALLED'}
if(-not (Test-Path -LiteralPath (Join-Path $root 'AuthSeed') -PathType Container)){throw 'NEWS_IMAGES_AUTH_SEED_MISSING'}
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not (Get-Command gh.exe -ErrorAction SilentlyContinue)){
  throw 'NEWS_GITHUB_AUTH_REQUIRED: gh auth login o GH_TOKEN'
}

# Drain only this service, cooperatively: never force-close an active image
# job or any browser profile. The two image slots finish their current work.
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task){Disable-ScheduledTask -TaskName $taskName | Out-Null}
[IO.File]::WriteAllText($flag,'TTN2_IMAGES_ENABLED=NO',$utf8)
$until=(Get-Date).AddMinutes(25)
do{
  $active=@(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(python|pythonw|py)\.exe$' -and
    [string]$_.CommandLine -match 'v2\.ttittulares\.news_images_v2'
  })
  if(-not $active.Count){break}
  if((Get-Date) -gt $until){throw 'NEWS_IMAGE_WORKERS_STILL_ACTIVE: esperando cierre propio, no se fuerza Chrome'}
  Write-Host ('TTN2_IMAGE_DRAIN_WAIT='+$active.Count)
  Start-Sleep -Seconds 10
}while($true)

$api='https://api.github.com/repos/fabricelop/europapress-rss'
$branch='feature/ttactualidad-v2-clean'
$headers=@{'User-Agent'='TTNoticiasV2-images-installer';'Accept'='application/vnd.github+json'}
$commit=Invoke-RestMethod -Uri ($api+'/commits/'+[Uri]::EscapeDataString($branch)) -Headers $headers
$sha=[string]$commit.sha
if($sha -notmatch '^[a-f0-9]{40}$'){throw 'NEWS_IMAGES_COMMIT_NOT_PINNED'}
$tree=Invoke-RestMethod -Uri ($api+'/git/trees/'+$sha+'?recursive=1') -Headers $headers
if($tree.truncated){throw 'NEWS_IMAGES_GIT_TREE_TRUNCATED'}
$code=Join-Path $root ('image-releases\'+$sha)
New-Item -ItemType Directory -Path $code -Force | Out-Null

# Keep the same complete dependency set as the verified editorial installer.
# This second release pointer is used only by the image task.
$news=@('news_workflow_v2.py','news_images_v2.py','test_news_workflow_v2.py','test_news_images_v2.py','editorial_browser_v2.py','editorial_consumer_v2.py','editorial_contract_v2.py',
  'editorial_state_v2.py','editorial_setup_v2.py','test_editorial_consumer_v2.py',
  'test_editorial_state_v2.py','test_editorial_contract_v2.py','test_contract_examples.py',
  'test_radar_snapshot_v2.py','test_radar_ingest_v2.py','test_editorial_browser_v2.py','test_editorial_setup_v2.py',
  'radar_snapshot_v2.py','radar_store_v2.py','radar_ingest_v2.py','identity_v2.py',
  'source_fetch_v2.py','source_publication_v2.py','source_catalog_v2.py','source_catalog_v2.json',
  'source_health_v2.py','content_filters_v2.py','schemas/contract.schema.json','examples/sample-bundle.json')
$shared=@('chrome_command_v2.py','chrome_visibility_v2.py','chrome_profile_process_v2.py',
          'chrome_cleanup_v2.py','chrome_startup_v2.py','process_lock_v2.py','image_intake_v2.py','image_same_chat_v2.py','image_job_v2.py','image_github_v2.py')
$paths=@($news | ForEach-Object {'v2/ttittulares/'+$_})+@($shared | ForEach-Object {'v2/ttendencias/'+$_})
$paths+=@('v2/ttittulares/Run-News-Images-Auto.ps1','v2/ttittulares/Launch-News-Hidden.vbs')
foreach($path in $paths){
  $entry=@($tree.tree | Where-Object {$_.path -eq $path -and $_.type -eq 'blob'})
  if($entry.Count -ne 1){throw ('NEWS_IMAGES_MISSING_FILE='+$path)}
  $target=Join-Path $code ($path.Replace('/','\'))
  New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/'+$path) -Headers $headers -OutFile $target
  $bytes=[IO.File]::ReadAllBytes($target)
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $hash=[Security.Cryptography.SHA1]::Create()
  try{$actual=([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  if($actual -ne $entry[0].sha){throw ('NEWS_IMAGES_GIT_HASH_MISMATCH='+$path)}
}

# A read-only check verifies the exact worker controls and image queue before
# activating another browser. No editorial task or active-code.txt is changed.
$logs=Join-Path $root 'image-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$probeOut=Join-Path $logs 'image-check.stdout.json'
$probeErr=Join-Path $logs 'image-check.stderr.log'
$probe=Start-Process -FilePath $py -WorkingDirectory $code -ArgumentList @('-3','-m','v2.ttittulares.news_images_v2','--root',('"'+$root+'"'),'--check') `
  -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
if($probe.ExitCode -ne 0){
  if(Test-Path $probeErr){Get-Content -LiteralPath $probeErr -Tail 12 | ForEach-Object {Write-Host $_}}
  throw ('NEWS_IMAGES_PREFLIGHT_FAILED='+$probe.ExitCode)
}
$result=Get-Content -LiteralPath $probeOut -Raw | ConvertFrom-Json
if($result.status -ne 'ok' -or $result.controls_ok -ne $true -or $null -eq $result.image_preview.pending_count){throw 'NEWS_IMAGES_PREFLIGHT_INCOMPLETE'}
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Run-News-Images-Auto.ps1') -Destination (Join-Path $root 'Run-News-Images-Auto.ps1') -Force
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Launch-News-Hidden.vbs') -Destination (Join-Path $root 'Launch-News-Hidden.vbs') -Force
[IO.File]::WriteAllText((Join-Path $root 'image-active-code.txt'),$code,$utf8)

if(-not $task){
  $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
  $wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
  $hidden=Join-Path $root 'Launch-News-Hidden.vbs'
  $action=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+$hidden+'" "'+(Join-Path $root 'Run-News-Images-Auto.ps1')+'"')
  $triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(3)) -RepetitionInterval (New-TimeSpan -Minutes 3)))
  $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $options=New-ScheduledTaskSettingsSet -Hidden -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $options -Force | Out-Null
}else{Enable-ScheduledTask -TaskName $taskName | Out-Null}
[IO.File]::WriteAllText($flag,'TTN2_IMAGES_ENABLED=YES',$utf8)
Start-ScheduledTask -TaskName $taskName
Write-Host ('TTN2_IMAGE_RELEASE='+$sha)
Write-Host ('TTN2_IMAGE_QUEUE_PENDING='+$result.image_preview.pending_count)
Write-Host ('TTN2_IMAGE_QUEUE_ACTIVE='+$result.image_preview.active_count)
Write-Host 'TTN2_IMAGE_WORKERS_START_REQUESTED=YES'
Write-Host ('TTN2_IMAGE_HEALTH='+ (Join-Path $root 'image-daemon-status.json'))
Write-Host 'TTN2_EDITORIAL_WINDOWS_TASK_UNCHANGED=YES'
