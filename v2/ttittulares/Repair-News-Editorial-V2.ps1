# Update only the News V2 editorial consumer. Allow existing chats to finish;
# do not stop the News V2 image daemon, any Chrome, Trends or V1 service.
[CmdletBinding()]
param([ValidatePattern('^[a-f0-9]{40}$')][string]$ReleaseSha)
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
$ref=if($ReleaseSha){$ReleaseSha}else{$branch}
$headers=@{'User-Agent'='TTNoticiasV2-editorial-repair';'Accept'='application/vnd.github+json'}
$rawHeaders=@{'User-Agent'='TTNoticiasV2-editorial-repair'}
# GitHub's unauthenticated API has a much lower request budget. The previous
# installer checked gh authentication but never actually sent it to GitHub.
# Restrict this credential to api.github.com, never to unrelated endpoints or
# the raw download CDN; do not write it into logs or console output.
$authToken=if($env:GH_TOKEN){$env:GH_TOKEN.Trim()}elseif($env:GITHUB_TOKEN){$env:GITHUB_TOKEN.Trim()}else{
  try{([string](& gh.exe auth token 2>$null)).Trim()}catch{''}
}
if(-not $authToken -or $authToken -match '\s'){throw 'NEWS_EDITORIAL_GITHUB_AUTH_REQUIRED'}
$headers['Authorization']='Bearer '+$authToken
# An audited release can be installed entirely from GitHub Raw. In particular,
# a GitHub API 403 cannot prevent its stage from even being downloaded. Every
# blob remains checked against its known Git SHA-1 below.
$auditedSha='01530a271a75f07a1e3f4060546d8df041ef784c'
$audited=($ReleaseSha -eq $auditedSha)
if($audited){
  $sha=$auditedSha
  $tree=$null
  Write-Host 'TTN2_EDITORIAL_PINNED_MANIFEST=YES'
}else{
  $commit=Invoke-RestMethod -Uri ($api+'/commits/'+[Uri]::EscapeDataString($ref)) -Headers $headers
  $sha=[string]$commit.sha
  if($sha -notmatch '^[a-f0-9]{40}$'){throw 'NEWS_EDITORIAL_COMMIT_NOT_PINNED'}
  if($ReleaseSha -and $sha -ne $ReleaseSha){throw 'NEWS_EDITORIAL_REQUESTED_RELEASE_MISMATCH'}
  $tree=Invoke-RestMethod -Uri ($api+'/git/trees/'+$sha+'?recursive=1') -Headers $headers
  if($tree.truncated){throw 'NEWS_EDITORIAL_GIT_TREE_TRUNCATED'}
}
$code=Join-Path $root ('releases\'+$sha)
New-Item -ItemType Directory -Path $code -Force | Out-Null
$news=@('news_workflow_v2.py','news_images_v2.py','test_news_workflow_v2.py','test_news_images_v2.py','editorial_browser_v2.py','news_process_inspection_v2.py','test_news_process_inspection_v2.py','editorial_consumer_v2.py','editorial_contract_v2.py','session_watchdog_v2.py','test_session_watchdog_v2.py',
  'pilot_one_v2.py',
  'editorial_state_v2.py','editorial_setup_v2.py','test_editorial_consumer_v2.py','test_editorial_quota_v2.py',
  'test_editorial_state_v2.py','test_editorial_contract_v2.py','test_contract_examples.py',
  'test_radar_snapshot_v2.py','test_radar_ingest_v2.py','test_editorial_browser_v2.py','test_editorial_setup_v2.py',
  'radar_snapshot_v2.py','radar_store_v2.py','radar_ingest_v2.py','identity_v2.py',
  'selection_v1_parity_v2.py','test_selection_v1_parity_v2.py',
  'source_fetch_v2.py','source_publication_v2.py','source_catalog_v2.py','source_catalog_v2.json',
  'source_health_v2.py','content_filters_v2.py','schemas/contract.schema.json','examples/sample-bundle.json',
  'probe_news_chat_response_v2.py','probe_news_editorial_shape_v2.py',
  'probe_news_existing_chat_v2.py')
$shared=@('chrome_command_v2.py','chrome_visibility_v2.py','chrome_profile_process_v2.py',
          'chrome_cleanup_v2.py','chrome_startup_v2.py','process_lock_v2.py','image_intake_v2.py','image_same_chat_v2.py','image_job_v2.py','image_github_v2.py')
$paths=@($news | ForEach-Object {'v2/ttittulares/'+$_})+@($shared | ForEach-Object {'v2/ttendencias/'+$_})
$paths+=@('v2/ttittulares/Run-News-Editorial-Auto.ps1')
$auditedBlobs=@{
  'v2/ttittulares/news_workflow_v2.py'='3a22459a3fe92a305883076d1f9aba2b8454b377'
  'v2/ttittulares/news_images_v2.py'='1d4d723d297d63a705ae343a4703d528afe00def'
  'v2/ttittulares/test_news_workflow_v2.py'='23ade20657719e403854765b2fcbc925437e7299'
  'v2/ttittulares/test_news_images_v2.py'='0ea59b0088817d5754389d1849cf0dcf49f55be7'
  'v2/ttittulares/editorial_browser_v2.py'='b24b4106f2942a7958f998f9eda9f0c2f1ec7d61'
  'v2/ttittulares/news_process_inspection_v2.py'='3e8a851892f204d6cbb6c9192be1447c15663aba'
  'v2/ttittulares/test_news_process_inspection_v2.py'='806d6c41388b907dd9532918dad634add790f645'
  'v2/ttittulares/editorial_consumer_v2.py'='b75798b30e6ff5bf893d104c5936ca93824fee3e'
  'v2/ttittulares/editorial_contract_v2.py'='81e11f02cef066b4498d5bc3f64777fcd5683d6d'
  'v2/ttittulares/session_watchdog_v2.py'='9924ab6127ce5a20ae9ca80d27cdee671858d6ad'
  'v2/ttittulares/test_session_watchdog_v2.py'='6cdcc7aa93377c0f8bc32810485478bfd7caec07'
  'v2/ttittulares/pilot_one_v2.py'='5c68f81d1c515587b7fe4a4b18474e09b901e3ad'
  'v2/ttittulares/editorial_state_v2.py'='433097df050d80a30e389a6ca5760b18cfd6d869'
  'v2/ttittulares/editorial_setup_v2.py'='7cbd755612f3e9915243432773bc66f9c74a2045'
  'v2/ttittulares/test_editorial_consumer_v2.py'='be76c0a1051377085790c3d7e0ed1ea7f517a2ab'
  'v2/ttittulares/test_editorial_quota_v2.py'='dc33576086a7df0371be8cacc1bde0803cdb6b15'
  'v2/ttittulares/test_editorial_state_v2.py'='ac1e17c2a30a5a802d1d48ea434647ab545e1863'
  'v2/ttittulares/test_editorial_contract_v2.py'='318cdf6717abf581da47157d9ef97f46bca48c0a'
  'v2/ttittulares/test_contract_examples.py'='67d16380e00874f7cadc6fbfd2f87f3976502445'
  'v2/ttittulares/test_radar_snapshot_v2.py'='271d46cd001a2551b6077e4fad4addb2e465b9b5'
  'v2/ttittulares/test_radar_ingest_v2.py'='3cceadc6a4a801ad8fae3f2c3a2992f801fa3117'
  'v2/ttittulares/test_editorial_browser_v2.py'='d497767ad95af29d1c35032fe95f9bfd693d9805'
  'v2/ttittulares/test_editorial_setup_v2.py'='d887569096cea246710c87738d3c0da5ed105667'
  'v2/ttittulares/radar_snapshot_v2.py'='9f59e2184340fdee22131091816e1426bdb5523c'
  'v2/ttittulares/radar_store_v2.py'='e56cf96168ae13d898eac8372337ba5980d65c68'
  'v2/ttittulares/radar_ingest_v2.py'='a8a2db35b04d6e0c9f89fee05a7630d81631a454'
  'v2/ttittulares/identity_v2.py'='f1c58f0f9fb043d22f55a97a4d8e83306cfc0dca'
  'v2/ttittulares/selection_v1_parity_v2.py'='8bbaab45a69e1d86773b3a2c36ec1e98d8ad5252'
  'v2/ttittulares/test_selection_v1_parity_v2.py'='7b966fbde7f18a3f6c0cd18181c7ee005a1ca4d9'
  'v2/ttittulares/source_fetch_v2.py'='75a5853233d35b6a12585a7ff0e03085223e2325'
  'v2/ttittulares/source_publication_v2.py'='dc75a02c982bd433c4bc839cd386db80fbe6eda5'
  'v2/ttittulares/source_catalog_v2.py'='6a465c05bc718c4a2219767ffb4a1003162c6bb9'
  'v2/ttittulares/source_catalog_v2.json'='3e0fde4c151058b2f5093d0c392763b76fb8225b'
  'v2/ttittulares/source_health_v2.py'='cd204cff6f6beb6aa54ef2fd1b2f992828ac522c'
  'v2/ttittulares/content_filters_v2.py'='b3490fa194885701b206b06ff6e86b25c6d846a7'
  'v2/ttittulares/schemas/contract.schema.json'='1aaecf2ab91819265919e28c4591db0ab109b4e8'
  'v2/ttittulares/examples/sample-bundle.json'='723c98ee295cf8e9e21b3fa09d5603bf17110afb'
  'v2/ttittulares/probe_news_chat_response_v2.py'='ef933fbdf37bd670c2175d623b3ff0a637bcc7e6'
  'v2/ttittulares/probe_news_editorial_shape_v2.py'='2e85e8d694048bca7f4280667b0e84483dfcc81b'
  'v2/ttittulares/probe_news_existing_chat_v2.py'='18e883f304a2498406706bbd6e9f1865f956092c'
  'v2/ttendencias/chrome_command_v2.py'='35d7f96fb52fc6d1c6364ef33bed1a156a4e1d9a'
  'v2/ttendencias/chrome_visibility_v2.py'='1fedb65cbbb6089fe21aba15f81923312ae01590'
  'v2/ttendencias/chrome_profile_process_v2.py'='e58cdc5e535898c8d27f9038baea2b5a9bd64130'
  'v2/ttendencias/chrome_cleanup_v2.py'='99b5a0cca0012dfc5a3d38575a4fe6dd7e23ae57'
  'v2/ttendencias/chrome_startup_v2.py'='a8b5c98e1f507d5f61a6f99ada55aed14475358f'
  'v2/ttendencias/process_lock_v2.py'='ef5731eb95a4eb91599360b4200d2b2d7792d650'
  'v2/ttendencias/image_intake_v2.py'='cdfa0543262a6d01f60c5bf4320b15dad8f516e8'
  'v2/ttendencias/image_same_chat_v2.py'='effbb1c64e67f981b4232b3dadede40dc90ea120'
  'v2/ttendencias/image_job_v2.py'='ad8c69566ad88b18f50e46e9a7f4b7cc4114e581'
  'v2/ttendencias/image_github_v2.py'='0d7298151f1ee3dcc1b9b252216cf2858ec43a60'
  'v2/ttittulares/Run-News-Editorial-Auto.ps1'='c7b6a2993240bb8dc6a8702aec153addd4586b41'
}
foreach($path in $paths){
  if($audited){
    $expectedBlob=[string]$auditedBlobs[$path]
    if($expectedBlob -notmatch '^[a-f0-9]{40}$'){throw ('NEWS_EDITORIAL_MISSING_FILE='+$path)}
  }else{
    $entry=@($tree.tree | Where-Object {$_.path -eq $path -and $_.type -eq 'blob'})
    if($entry.Count -ne 1){throw ('NEWS_EDITORIAL_MISSING_FILE='+$path)}
    $expectedBlob=[string]$entry[0].sha
  }
  $target=Join-Path $code ($path.Replace('/','\'))
  New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/'+$path) -Headers $rawHeaders -OutFile $target
  $bytes=[IO.File]::ReadAllBytes($target)
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $hash=[Security.Cryptography.SHA1]::Create()
  try{$actual=([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  if($actual -ne $expectedBlob){throw ('NEWS_EDITORIAL_GIT_HASH_MISMATCH='+$path)}
}

# psutil inspects the exact owned Chrome command lines natively. In this
# Windows account it replaces the PowerShell/CIM loops that timed out while
# several editorial jobs were starting. Validate before draining live chats.
$dependencyOut=Join-Path $root 'news-psutil.stdout.log'
$dependencyErr=Join-Path $root 'news-psutil.stderr.log'
$dependency=Start-Process -FilePath $py -ArgumentList @('-3','-c','"import psutil"') `
  -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $dependencyOut -RedirectStandardError $dependencyErr
if($dependency.ExitCode -ne 0){
  $installDependency=Start-Process -FilePath $py -ArgumentList @('-3','-m','pip','install','--user','psutil') `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $dependencyOut -RedirectStandardError $dependencyErr
  if($installDependency.ExitCode -ne 0){throw 'NEWS_EDITORIAL_PSUTIL_INSTALL_FAILED'}
}
$testOut=Join-Path $root 'news-editorial-stage.stdout.log'
$testErr=Join-Path $root 'news-editorial-stage.stderr.log'
$tests=Start-Process -FilePath $py -WorkingDirectory $code `
  -ArgumentList @('-3','-m','unittest','v2.ttittulares.test_editorial_browser_v2', `
                   'v2.ttittulares.test_editorial_consumer_v2', `
                   'v2.ttittulares.test_editorial_quota_v2', `
                   'v2.ttittulares.test_news_process_inspection_v2', `
                   'v2.ttittulares.test_editorial_state_v2','-q') `
  -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $testOut -RedirectStandardError $testErr
if($tests.ExitCode -ne 0){
  if(Test-Path -LiteralPath $testErr){Get-Content -LiteralPath $testErr -Tail 15 | ForEach-Object {Write-Host $_}}
  throw 'NEWS_EDITORIAL_STAGE_TESTS_FAILED: no se ha cambiado la instalación activa'
}
Write-Host 'TTN2_EDITORIAL_STAGE_TESTS=OK'

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
  Write-Host 'TTN2_EDITORIAL_NATIVE_CHROME_INSPECTION=YES'
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

