# Installs only the news V2 consumer; no V1, trends tasks or Chrome are stopped.
[CmdletBinding()]
param([string]$SeedProfile='', [switch]$PrepareOnly, [switch]$EnableImages)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$taskName='TTActualidadNoticiasV2-Editorial'
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN -and -not (Get-Command gh.exe -ErrorAction SilentlyContinue)){
  throw 'Falta autenticación GitHub: gh auth login o GH_TOKEN'
}
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and $existing.State -eq 'Running'){throw 'El consumidor de Noticias V2 sigue activo; dejar que termine antes de actualizar'}
if($existing){Disable-ScheduledTask -TaskName $taskName | Out-Null}
$active=@(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -match '^(python|pythonw|py)\.exe$' -and [string]$_.CommandLine -match 'v2\.ttittulares\.(editorial_consumer_v2|news_images_v2)'
})
if($active.Count){throw 'Hay un consumidor Noticias V2 vivo. No se reemplazan sus archivos ni se termina su Chrome'}
New-Item -ItemType Directory -Path $root -Force | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $root 'editorial.enabled'),'TTN2_EDITORIAL_ENABLED=NO',$utf8)
# Journals and cloned browser credentials are accessible only to this Windows user.
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $root /inheritance:r /grant:r ($user+':(OI)(CI)F') | Out-Null
if($LASTEXITCODE -ne 0){throw 'No se pudo proteger la carpeta privada Noticias V2'}
$headers=@{'User-Agent'='TTNoticiasV2-installer';'Accept'='application/vnd.github+json'}
$api='https://api.github.com/repos/fabricelop/europapress-rss'
$branch='feature/ttactualidad-v2-clean'
$head=Invoke-RestMethod -Uri ($api+'/commits/'+[Uri]::EscapeDataString($branch)) -Headers $headers
$sha=[string]$head.sha
if($sha -notmatch '^[a-f0-9]{40}$'){throw 'No se pudo fijar el commit Noticias V2'}
$tree=Invoke-RestMethod -Uri ($api+'/git/trees/'+$sha+'?recursive=1') -Headers $headers
if($tree.truncated){throw 'Inventario Git incompleto; no instalar'}
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
$paths+=@('v2/ttittulares/Run-News-Editorial-Auto.ps1','v2/ttittulares/Run-News-Images-Auto.ps1','v2/ttittulares/Launch-News-Hidden.vbs',
  'v2/ttittulares/Check-News-V2-Health.ps1','v2/ttittulares/Sweep-V2-Disposable-Sessions.ps1')
foreach($path in $paths){
  $entry=@($tree.tree | Where-Object {$_.path -eq $path -and $_.type -eq 'blob'})
  if($entry.Count -ne 1){throw ('Falta archivo en el commit fijado: '+$path)}
  $target=Join-Path $code ($path.Replace('/','\'))
  New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/'+$path) -Headers $headers -OutFile $target
  $bytes=[IO.File]::ReadAllBytes($target)
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $hash=[Security.Cryptography.SHA1]::Create()
  try{$actual=([BitConverter]::ToString($hash.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  if($actual -ne $entry[0].sha){throw ('Archivo descargado no coincide con Git: '+$path)}
}
function Invoke-NewsPython([string[]]$arguments){
  $out=Join-Path $root 'install.stdout.log';$err=Join-Path $root 'install.stderr.log'
  $result=Start-Process -FilePath $py -ArgumentList (@('-3')+$arguments) -WorkingDirectory $code `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if(Test-Path $out){Get-Content $out | ForEach-Object {Write-Host $_}}
  if($result.ExitCode -ne 0){
    if(Test-Path $err){Get-Content $err -Tail 15 | ForEach-Object {Write-Host $_}}
    throw ('Noticias V2: fase no verificada, exit='+$result.ExitCode+'; no se activa el programador')
  }
}
# Resolve the news schema dependency in the SAME py -3 interpreter used below.
$dependency=Start-Process -FilePath $py -ArgumentList @('-3','-c','"import jsonschema"') -WindowStyle Hidden -Wait -PassThru `
  -RedirectStandardOutput (Join-Path $root 'dependency-check.stdout.log') `
  -RedirectStandardError (Join-Path $root 'dependency-check.stderr.log')
if($dependency.ExitCode -ne 0){
  Invoke-NewsPython -arguments @('-m','pip','install','--user','jsonschema==4.23.0')
}
Invoke-NewsPython -arguments @('-m','pip','install','--user','Pillow')
Invoke-NewsPython -arguments @('-c','"import playwright.sync_api, jsonschema, PIL"')
Invoke-NewsPython -arguments @('-m','unittest','v2.ttittulares.test_contract_examples','v2.ttittulares.test_editorial_contract_v2','v2.ttittulares.test_editorial_state_v2','v2.ttittulares.test_editorial_consumer_v2','v2.ttittulares.test_editorial_browser_v2','v2.ttittulares.test_news_workflow_v2','v2.ttittulares.test_news_images_v2','v2.ttittulares.test_session_watchdog_v2')
$chrome=Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
$setup=@('-m','v2.ttittulares.editorial_setup_v2','--root',('"'+$root+'"'),'--chrome',('"'+$chrome+'"'))
if($SeedProfile){$setup+=@('--seed-source',('"'+$SeedProfile+'"'))}
Invoke-NewsPython -arguments $setup
Invoke-NewsPython -arguments @('-m','v2.ttittulares.editorial_consumer_v2','--root',('"'+$root+'"'),'--check')
$queuePreview=Get-Content -LiteralPath (Join-Path $root 'install.stdout.log') -Raw | ConvertFrom-Json
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Run-News-Editorial-Auto.ps1') -Destination (Join-Path $root 'Run-News-Editorial-Auto.ps1') -Force
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Check-News-V2-Health.ps1') -Destination (Join-Path $root 'Check-News-V2-Health.ps1') -Force
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Sweep-V2-Disposable-Sessions.ps1') -Destination (Join-Path $root 'Sweep-V2-Disposable-Sessions.ps1') -Force
[IO.File]::WriteAllText((Join-Path $root 'active-code.txt'),$code,$utf8)
Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Launch-News-Hidden.vbs') -Destination (Join-Path $root 'Launch-News-Hidden.vbs') -Force
Write-Host ('TTN2_INSTALLED_COMMIT='+$sha)
if($PrepareOnly){Write-Host 'TTN2_INSTALLED_NOT_STARTED=YES';return}
if($null -eq $queuePreview.preview.blocking_recovery_incident_count -or $null -eq $queuePreview.preview.quarantined_incident_count){
  throw 'Noticias V2: falta clasificacion verificada de incidencias; no se activa el programador.'
}
if([int]$queuePreview.preview.blocking_recovery_incident_count -gt 0){
  # Existing uncertain jobs remain isolated by their own durable state. The
  # consumer claims pending jobs only; an unrelated new pilot is safe to run.
  Write-Host ('TTN2_EDITORIAL_UNCERTAIN_INCIDENTS_ISOLATED='+$queuePreview.preview.blocking_recovery_incident_count)
  Write-Host 'TTN2_EDITORIAL_NO_RETRY_OLD_COMMANDS=YES'
}
if([int]$queuePreview.preview.quarantined_incident_count -gt 0){
  Write-Host ('TTN2_EDITORIAL_INCIDENTS_QUARANTINED='+$queuePreview.preview.quarantined_incident_count)
}
# Verify one complete transport/capture/cleanup cycle before enabling 3 slots.
# A durably quarantined validation rejection never becomes READY or gets resent.
Invoke-NewsPython -arguments @('-m','v2.ttittulares.editorial_consumer_v2','--root',('"'+$root+'"'),'--run-one')
$pilot=Get-Content -LiteralPath (Join-Path $root 'install.stdout.log') -Raw | ConvertFrom-Json
if($pilot.status -notin @('ready','idle','quarantined')){throw 'Piloto editorial sin resultado confirmado; no se activa el programador'}
if($pilot.status -in @('ready','quarantined') -and -not $pilot.cleanup_verified){throw 'Cierre Chrome no verificado; no se activa el programador'}
if($pilot.status -eq 'quarantined'){
  if($pilot.error_type -ne 'ContractError' -or $pilot.submission_confirmed -ne $true -or
     $pilot.capture_complete -ne $true -or $pilot.capture_persisted -ne $true -or
     $pilot.failure_persisted -ne $true -or $pilot.cleanup_verified -ne $true){
    throw 'Incidencia del piloto sin captura, persistencia y cierre confirmados; no se activa.'
  }
  Write-Host 'TTN2_PILOT=QUARANTINED_AND_VERIFIED_NO_RESEND'
}
if($pilot.status -eq 'idle'){Write-Host 'TTN2_PILOT_IDLE_NO_NEWS_ELABORATED=YES'}
[IO.File]::WriteAllText((Join-Path $root 'editorial.enabled'),'TTN2_EDITORIAL_ENABLED=YES',$utf8)
$hiddenLauncher=Join-Path $root 'Launch-News-Hidden.vbs'
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$action=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+$hiddenLauncher+'" "'+(Join-Path $root 'Run-News-Editorial-Auto.ps1')+'"')
$trigger=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(3)) -RepetitionInterval (New-TimeSpan -Minutes 3)))
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$options=New-ScheduledTaskSettingsSet -Hidden -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $options -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host 'TTN2_THREE_WORKERS_START_REQUESTED=YES'
Write-Host ('LOGS='+ (Join-Path $root 'logs'))
Write-Host 'TTN2_SCHEDULED_LAUNCHER=WSCRIPT_HIDDEN'

if($EnableImages){
  Copy-Item -LiteralPath (Join-Path $code 'v2\ttittulares\Run-News-Images-Auto.ps1') -Destination (Join-Path $root 'Run-News-Images-Auto.ps1') -Force
  try{
    # Independent pilot: failure never disables the already verified editorial task.
    Invoke-NewsPython -arguments @('-m','v2.ttittulares.news_images_v2','--root',('"'+$root+'"'),'--run-one')
    $imagePilot=Get-Content -LiteralPath (Join-Path $root 'install.stdout.log') -Raw | ConvertFrom-Json
    if($imagePilot.status -notin @('saved','idle')){throw 'Imagen piloto sin verificar'}
    if($imagePilot.status -eq 'saved' -and (-not $imagePilot.cleanup_verified -or -not $imagePilot.verified)){
      throw 'Imagen no confirmada en GitHub y en el estado editorial, o cierre Chrome no verificado'
    }
    if($imagePilot.status -eq 'saved'){
      Write-Host 'TTN2_IMAGE_E2E_VERIFIED=YES'
      Write-Host ('TTN2_IMAGE_LOCAL_ORIGINAL_RECLAIMED='+$imagePilot.local_original_reclaimed)
    }else{
      Write-Host 'TTN2_IMAGE_E2E_VERIFIED=NO_PENDING_IMAGE; NO_AFIRMAR_PRUEBA_REAL'
    }
    [IO.File]::WriteAllText((Join-Path $root 'images.enabled'),'TTN2_IMAGES_ENABLED=YES',$utf8)
    $imageAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+$hiddenLauncher+'" "'+(Join-Path $root 'Run-News-Images-Auto.ps1')+'"')
    Register-ScheduledTask -TaskName 'TTActualidadNoticiasV2-Images' -Action $imageAction -Trigger $trigger -Principal $principal -Settings $options -Force | Out-Null
    Start-ScheduledTask -TaskName 'TTActualidadNoticiasV2-Images'
    Write-Host 'TTN2_IMAGE_WORKERS_START_REQUESTED=YES'
  }catch{
    [IO.File]::WriteAllText((Join-Path $root 'images.enabled'),'TTN2_IMAGES_ENABLED=NO',$utf8)
    Write-Host ('TTN2_IMAGES_NOT_ENABLED='+$_.Exception.GetType().Name)
    Write-Host 'TTN2_EDITORIAL_TASK_CONTINUES=YES'
    throw
  }
}
