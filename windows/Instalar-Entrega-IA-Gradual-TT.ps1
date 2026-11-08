#requires -Version 5.1
<#
 TTActualidad: gradual delivery of generated ImageGen originals to existing
 approval inbox, bound by project+ID+revision+command+episode SHA.
 Dry run by default. -Apply installs and starts a separate 15-minute schedule.
 Does not touch TTImages capture, Telegram, generation, X, Buffer or Chrome.
#>
[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$base='C:\TTiTTulares'
$receiver=Join-Path $base 'TTImageApprovalReceiver.cjs'
$oldTaskName='TT Actualidad - Imagenes pendientes APP'
$newTaskName='TT Actualidad - Entrega IA gradual'
$home=Join-Path $env:LOCALAPPDATA 'TTImageInbox'
$launcher=Join-Path $home 'Run-TTImageInbox-Hidden.vbs'
$runner=Join-Path $home 'Run-TTImageInbox.ps1'
function Note([string]$code,[string]$value=''){Write-Host ('TT_IMAGE_INBOX '+$code+' '+$value)}
function RequireMarkers([string]$file,[string[]]$markers,[string]$name){
  if(-not(Test-Path -LiteralPath $file)){throw ($name+'_NOT_INSTALLED')}
  $source=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)
  foreach($marker in $markers){
    if(-not $source.Contains($marker)){throw ($name+'_INCOMPATIBLE: '+$marker)}
  }
}
RequireMarkers $receiver @(
  '/api/image-inbox/v1/images/ingest',
  'MAX_NEW_RELAY_TABS_PER_CYCLE=1',
  'MAX_RELAY_PAGE_TARGETS=6',
  'RELAY_RETRY_COOLDOWN_MS=15*60*1000',
  'MAX_ORIGINAL_CHECKS_PER_CYCLE=16',
  'Target.closeTarget',
  'function metadata(task,job)',
  'function provesTop30AtImageCreation',
  'PRIVATE_RECEIPT_REJECTED'
) 'RECEIVER'
foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')){
  RequireMarkers (Join-Path $base $name) @(
    "return {status:'waiting',reason:'manual_approval_required'}",
    'readImageJob','readEditorialState','rasterProbe','discoverConversation'
  ) ('DEPENDENCY_'+$name)
}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$ws=(& $node -p 'typeof WebSocket' 2>$null | Select-Object -First 1)
if(([string]$ws).Trim() -ne 'function'){throw 'NODE_NATIVE_WEBSOCKET_REQUIRED'}
$old=Get-ScheduledTask -TaskName $oldTaskName -ErrorAction Stop
if($old.State -ne 'Disabled'){
  throw ('OLD_RECEIVER_MUST_REMAIN_DISABLED: '+$old.State+'. No segunda programacion simultanea.')
}
$existing=Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue
if($existing){
  $acts=@($existing.Actions)
  if($acts.Count -ne 1 -or
    [IO.Path]::GetFileName([string]$acts[0].Execute) -ine 'wscript.exe' -or
    [string]$acts[0].Arguments -notlike '*Run-TTImageInbox-Hidden.vbs*'){
    throw 'TASK_NAME_CONFLICT: existing task not owned by installer'
  }
}
Note 'PREFLIGHT_OK' 'receiver and both paused consumers; old schedule Disabled'
if(-not $Apply){
  Note 'DRY_RUN' 'Sin cambios; usar -Apply para instalar entrega gradual'
  return
}
if(-not(Test-Path -LiteralPath $home)){New-Item -ItemType Directory -Path $home -Force|Out-Null}
$runnerText=@'
#requires -Version 5.1
# One receiver pass. No prompts, edits, approval or publication.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$home=Join-Path $env:LOCALAPPDATA 'TTImageInbox'
$log=Join-Path $home 'delivery.log'
try {
  $old=Get-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -ErrorAction Stop
  if($old.State -ne 'Disabled'){Add-Content -LiteralPath $log -Value 'SKIP_OLD_SCHEDULE_ACTIVE';exit 0}
  $receiver=Join-Path $base 'TTImageApprovalReceiver.cjs'
  if(-not(Test-Path -LiteralPath $receiver)){throw 'RECEIVER_MISSING'}
  $node=(Get-Command node.exe -ErrorAction Stop).Source
  if((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 2097152){
    Move-Item -LiteralPath $log -Destination ($log+'.previous') -Force
  }
  Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('o')+' BEGIN')
  & $node $receiver *>> $log
  $code=$LASTEXITCODE
  Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('o')+' END exit='+$code)
  if($code -ne 0){exit $code}
}catch{
  Add-Content -LiteralPath $log -Value ((Get-Date).ToUniversalTime().ToString('o')+' FAIL receiver_not_executed')
  exit 1
}
'@
$vbsText=@'
Option Explicit
Dim shell, fso, folder, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(folder, "Run-TTImageInbox.ps1")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
shell.Run cmd, 0, True
'@
$tmpRunner=$runner+'.new'
$tmpLauncher=$launcher+'.new'
[IO.File]::WriteAllText($tmpRunner,$runnerText,[Text.Encoding]::UTF8)
[IO.File]::WriteAllText($tmpLauncher,$vbsText,[Text.Encoding]::ASCII)
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($tmpRunner,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){throw 'RUNNER_POWERSHELL_SYNTAX_INVALID'}
Move-Item -LiteralPath $tmpRunner -Destination $runner -Force
Move-Item -LiteralPath $tmpLauncher -Destination $launcher -Force
$execute=Join-Path $env:SystemRoot 'System32\wscript.exe'
$arguments='//B //Nologo "'+$launcher+'"'
$action=New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $home
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 12) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $newTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Entrega IA gradual a la bandeja; solo aprobacion manual' -Force|Out-Null
$installed=Get-ScheduledTask -TaskName $newTaskName -ErrorAction Stop
if($installed.State -eq 'Disabled'){throw 'SCHEDULE_CREATED_BUT_DISABLED'}
if((Get-ScheduledTask -TaskName $oldTaskName).State -ne 'Disabled'){
  Disable-ScheduledTask -TaskName $newTaskName|Out-Null
  throw 'OLD_SCHEDULE_CHANGED: gradual delivery disabled'
}
Note 'INSTALLED' ('interval=15min maxRelayTabs=1 state='+$installed.State)
Start-ScheduledTask -TaskName $newTaskName -ErrorAction Stop
Note 'START_REQUESTED' ('check '+(Join-Path $base 'image-approval-receipts\receiver-cycle.json'))
Note 'NO_APPROVAL_NO_PUBLICATION' 'Cada original requiere decision manual del editor'
