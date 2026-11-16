# Real Windows XML/WSH regression. No scheduled task is registered or launched.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
. (Join-Path $root 'News-HiddenTask-Xml.ps1')
$runner='C:\News V2\Run-News-Editorial-Auto.ps1'
$launcher='C:\News V2\Launch-News-Hidden.vbs'
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$service=New-Object -ComObject 'Schedule.Service'
$service.Connect()
$definition=$service.NewTask(0)
$definition.RegistrationInfo.Description='News hidden launcher regression fixture'
$definition.Settings.Enabled=$false
$definition.Settings.Hidden=$false
$definition.Settings.MultipleInstances=2
$definition.Settings.ExecutionTimeLimit='PT0S'
$trigger=$definition.Triggers.Create(2)
$trigger.StartBoundary='2026-11-16T10:00:00'
$trigger.DaysInterval=1
$action=$definition.Actions.Create(0)
$action.Path='powershell.exe'
$action.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$runner+'"'
$original=$definition.XmlText
$changed=ConvertTo-NewsHiddenTaskXml -Xml $original -Runner $runner -Launcher $launcher -Wscript $wscript
$parsed=$service.NewTask(0)
$parsed.XmlText=$changed
if($parsed.Settings.Enabled -ne $false -or -not $parsed.Settings.Hidden -or $parsed.Settings.MultipleInstances -ne 2){throw 'HIDDEN_SETTINGS_NOT_PRESERVED'}
if($parsed.Actions.Item(1).Path -ine $wscript){throw 'HIDDEN_EXECUTABLE_INVALID'}
if($parsed.Actions.Item(1).Arguments -cne ('//B //Nologo "'+$launcher+'" "'+$runner+'"')){throw 'HIDDEN_ARGUMENTS_INVALID'}
[xml]$old=$original;[xml]$new=$changed
foreach($section in @('Triggers','Principals','RegistrationInfo')){
 if($old.Task.$section.OuterXml -cne $new.Task.$section.OuterXml){throw ('SECTION_CHANGED_'+$section)}
}
$again=ConvertTo-NewsHiddenTaskXml -Xml $changed -Runner $runner -Launcher $launcher -Wscript $wscript
[xml]$againXml=$again
if($againXml.Task.Actions.Exec.Command -ine $wscript){throw 'HIDDEN_NOT_IDEMPOTENT'}
$rejected=$false
try{ConvertTo-NewsHiddenTaskXml -Xml $original -Runner 'C:\Other\unrelated.ps1' -Launcher $launcher -Wscript $wscript|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'CUSTOM_TASK_NOT_PRESERVED'}
$repair=Get-Content -LiteralPath (Join-Path $root 'Repair-News-Hidden-Launchers-V2.ps1') -Raw
if($repair -match 'Stop-Process|Stop-ScheduledTask|Start-ScheduledTask|Disable-ScheduledTask|Enable-ScheduledTask|taskkill|images\.enabled|editorial\.enabled'){throw 'REPAIR_INTERRUPTS_EXISTING_JOBS'}
$install=Get-Content -LiteralPath (Join-Path $root 'Install-News-Editorial-V2.ps1') -Raw
if($install -match "New-ScheduledTaskAction -Execute 'powershell.exe'"){throw 'INSTALLER_STILL_CREATES_CONSOLE_TASK'}
if($install -notmatch 'New-ScheduledTaskSettingsSet -Hidden'){throw 'INSTALLER_TASK_NOT_HIDDEN'}
if($install -notmatch 'Launch-News-Hidden\.vbs'){throw 'INSTALLER_WRAPPER_NOT_INSTALLED'}
$temp=Join-Path $env:TEMP ('news-hidden-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force|Out-Null
try{
 $probe=Join-Path $temp 'Probe With Spaces.ps1'
 $proof=Join-Path $temp 'proof.txt'
 $escaped=$proof.Replace("'","''")
 [IO.File]::WriteAllText($probe,("[IO.File]::WriteAllText('"+$escaped+"','completed'); exit 17"),(New-Object Text.UTF8Encoding($false)))
 $wrapper=Join-Path $root 'Launch-News-Hidden.vbs'
 $process=Start-Process -FilePath $wscript -ArgumentList @('//B','//Nologo',('"'+$wrapper+'"'),('"'+$probe+'"')) -Wait -PassThru
 if($process.ExitCode -ne 17 -or -not (Test-Path -LiteralPath $proof)){throw 'WSCRIPT_DID_NOT_WAIT_OR_PROPAGATE_EXIT_CODE'}
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host 'TTN2_HIDDEN_XML_TRIGGERS_FLAGS_PRINCIPAL=PASS'
Write-Host 'TTN2_HIDDEN_REPAIR_NO_RUNNING_JOB_INTERRUPTION=PASS'
Write-Host 'TTN2_WSCRIPT_HIDDEN_WAIT_AND_EXIT_CODE=PASS'
