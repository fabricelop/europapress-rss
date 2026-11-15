$ErrorActionPreference='Stop'
$repo=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$paths=@(
  'windows/Disable-TTendencias-V1-Local.ps1',
  'windows/Prepare-TTendencias-V1-Local.ps1',
  'windows/TT-LocalWatchdog.ps1',
  'windows/TT-AutoUpdater.ps1',
  'windows/TTendenciasDedicatedListener.ps1',
  'windows/TTendenciasMobileChatTriggerListener.ps1',
  'windows/Run-TTendencias-X-Local.ps1'
)
foreach($rel in $paths){
  $path=Join-Path $repo $rel
  $tokens=$null;$errors=$null
  [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){throw ('PowerShell invalido en '+$rel+': '+$errors[0].Message)}
}
$watch=[IO.File]::ReadAllText((Join-Path $repo 'windows/TT-LocalWatchdog.ps1'))
$update=[IO.File]::ReadAllText((Join-Path $repo 'windows/TT-AutoUpdater.ps1'))
$listen=[IO.File]::ReadAllText((Join-Path $repo 'windows/TTendenciasDedicatedListener.ps1'))
$mobile=[IO.File]::ReadAllText((Join-Path $repo 'windows/TTendenciasMobileChatTriggerListener.ps1'))
$x=[IO.File]::ReadAllText((Join-Path $repo 'windows/Run-TTendencias-X-Local.ps1'))
$retire=[IO.File]::ReadAllText((Join-Path $repo 'windows/Disable-TTendencias-V1-Local.ps1'))
$prepare=[IO.File]::ReadAllText((Join-Path $repo 'windows/Prepare-TTendencias-V1-Local.ps1'))
$required=@(
  @($watch,'if(TrendsV1Enabled){EnsureSingle "*TTendenciasDedicatedListener.ps1*"'),
  @($watch,'if(TrendsV1Enabled){EnsureStartup "TTendencias Mobile Trigger Listener.cmd"'),
  @($watch,'if(TrendsV1Enabled){$taskNames+="TTendencias Local"}'),
  @($watch,'if($spec.project -eq "ttendencias" -and -not (TrendsV1Enabled)){continue}'),
  @($update,'SKIP RETIRED TRENDS RESTART'),
  @($listen,'V1 RETIRED; listener exits'),
  @($mobile,'V1 RETIRED; mobile receiver exits'),
  @($x,'TT_X_WINDOWS RETIRED: no work'),
  @($retire,"[ValidateSet('Status','Disable','Restore')]"),
  @($retire,"TTActualidadV2-Editorial-Auto"),
  @($retire,"TTendencias-XContext"),
  @($retire,"function AssertDisabled"),
  @($retire,"function WaitForQuiet"),
  @($retire,"function RestartSharedSupervisors"),
  @($retire,"TT_V1_SHARED_SUPERVISORS_RELOADED=YES"),
  @($retire,"\u0027PARTIAL\u0027"),
  @($retire,"TT_V1_RETIRE_NO_NEW_WORK=YES"),
  @($retire,"TT_V1_BACKUP_READY=YES"),
  @($prepare,"TT_V1_SHARED_UPDATER_PREPARED=YES"),
  @($prepare,"-before-retirement-"),
  @($prepare,"TTendenciasMobileChatTriggerListener.ps1")
)
foreach($check in $required){
  if(-not ([string]$check[0]).Contains([string]$check[1])){throw ('Falta proteccion: '+$check[1])}
}
# La marca que impide nuevos trabajos debe escribirse ANTES de esperar.
$flagPos=$retire.IndexOf("[IO.File]::WriteAllText(`$flag,")
$drainPos=$retire.LastIndexOf("WaitForQuiet")
if($flagPos -lt 0 -or $drainPos -le $flagPos -or $retire.Contains('TT_V1_RETIRE_DEFERRED=NEW_WORK_STARTED')){
  throw 'La retirada todavia puede entrar en carrera con trabajos V1 nuevos'
}
if($retire -match '(?i)Stop-Process.*Chrome|Stop-Process.*TTiTTulares|Disable-ScheduledTask.*TTActualidadV2'){
  throw 'El instalador no puede parar Chrome, TTiTTulares ni V2'
}
$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows/Disable-TTendencias-V1-Local.ps1') -Action Status 2>&1
if($LASTEXITCODE -ne 0){throw ('El diagnostico solo lectura fallo: '+($output -join ' '))}
if(-not (($output -join "`n") -match 'TT_V1_WINDOWS_DISABLED=')){throw 'No se recibio estado de retirada'}
Write-Host 'TT_V1_RETIRE_WINDOWS_TESTS=OK'
