$ErrorActionPreference='Stop'
$repair=Join-Path $PSScriptRoot '..\Repair-TT-V1-Watchdog-Retirement.ps1'
$baselinePath=Join-Path $PSScriptRoot 'fixtures\TT-LocalWatchdog.pre-retirement.ps1.txt'
$publishedPath=Join-Path $PSScriptRoot '..\TT-LocalWatchdog.ps1'
function Parse-Source([string]$Source){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw (($errors | ForEach-Object {('line '+$_.Extent.StartLineNumber+': '+$_.Extent.Text+' => '+$_.Message)}) -join "`n")}
  return $ast
}
$repairAst=Parse-Source ([IO.File]::ReadAllText($repair))
foreach($name in @('Add-TTV1WatchdogRetirement','Test-TTExactWatchdogProcess')){
  $function=$repairAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0]
  Invoke-Expression $function.Extent.Text
}
$baseline=[IO.File]::ReadAllText($baselinePath)
$result=Add-TTV1WatchdogRetirement $baseline
if(-not $result.changed){throw 'Original watchdog not patched'}
$published=[IO.File]::ReadAllText($publishedPath)
if($result.source.Replace("`r`n","`n").TrimEnd() -cne $published.Replace("`r`n","`n").TrimEnd()){
  throw 'Published watchdog differs from surgical patch of validated baseline'
}
$oldAst=Parse-Source $baseline;$newAst=Parse-Source $result.source
foreach($name in @('EnsureChrome','EnsureChromeTabHousekeeping','EnsureInternetRecovery','EnsureEditorialGuardCapacity','MeasureChrome9223Pressure')){
  $before=$oldAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0].Extent.Text
  $after=$newAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0].Extent.Text
  if($before -cne $after){throw ('Shared behavior changed: '+$name)}
}
$slrBlock='$slr=Get-ScheduledTask -TaskName "SeLoRecordamos-Telegram"'
if(-not $result.source.Contains($slrBlock)){throw 'Shared SLR task maintenance lost'}
$localHotfix=$baseline.Replace('function EnsureSingle([string]$Pattern,[string]$Script,[string]$Tag){',"function EnsureSingle([string]`$Pattern,[string]`$Script,[string]`$Tag){`n  # LOCAL_USER_HOTFIX_KEEP_EXACT")
$hotfixResult=Add-TTV1WatchdogRetirement $localHotfix
if(-not $hotfixResult.source.Contains('# LOCAL_USER_HOTFIX_KEEP_EXACT')){throw 'Unseen local hotfix lost'}
$again=Add-TTV1WatchdogRetirement $result.source
if($again.changed -or $again.source -cne $result.source){throw 'Patch not idempotent'}
$rejected=$false
try{[void](Add-TTV1WatchdogRetirement ($baseline.Replace('foreach($name in $taskNames)','foreach($unknown in $taskNames)')))}catch{$rejected=$true}
if(-not $rejected){throw 'Unknown loop contract accepted'}

# Load only selected function definitions, never the watchdog's executable loop.
foreach($name in @('Test-TTV1ProjectRetired','Test-TTV1ScriptRetired','Test-TTV1TaskRetired','TrendsV1Enabled',
  'StartHiddenPs','EnsureSingle','EnsureStartup','EnsureScheduledTasks','Recover-ListenersAfterReconnect',
  'EnsureTTitRequestedImageRecovery','EnsureEditorialScheduledWake','EnsureRemoteTelegramHeal')){
  $function=$newAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)[0]
  Invoke-Expression $function.Extent.Text
}
$temp=Join-Path $env:TEMP ('tt-watchdog-retirement-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$BaseDir=$temp;$TrendsV1RetiredFlag=Join-Path $BaseDir 'TTendencias-V1-Disabled.flag'
function Log([string]$Text){}
function Get-ScheduledTask($TaskName,$TaskPath,$ErrorAction){
  [pscustomobject]@{TaskName=$TaskName;TaskPath='\';State=$(if($TaskName -eq 'SeLoRecordamos-Telegram'){'Running'}else{'Disabled'})}
}
function Enable-ScheduledTask($TaskName,$ErrorAction){$global:ttTestEnabled+=([string]$TaskName)}
function Start-ScheduledTask($TaskName,$ErrorAction){$global:ttTestJobStarts++;throw 'Unexpected job launch in test'}
function Start-Process{$global:ttTestStarts++;throw 'Retired listener unexpectedly launched'}
function Stop-Process{$global:ttTestStops++;throw 'Unexpected process termination'}
function PsProcs{throw 'Retired listener unexpectedly queried'}
function Invoke-RestMethod{$global:ttTestNetworkCalls++;throw 'Retired V1 recovery made a network request'}
function Test-ChatOperationBusy{return $false}
function Test-EditorialRunnerBusy{return $false}
try{
  $global:ttTestStarts=0;$global:ttTestStops=0;$global:ttTestNetworkCalls=0;$global:ttTestJobStarts=0
  $global:ttTestEnabled=@();EnsureScheduledTasks
  if($global:ttTestEnabled -notcontains 'TTiTTulares Local' -or $global:ttTestEnabled -notcontains 'TTendencias Local'){throw 'Active V1 baseline behavior changed'}
  New-Item -ItemType File -Path (Join-Path $BaseDir 'TTiTTulares-V1-Disabled.flag') | Out-Null
  $global:ttTestEnabled=@();EnsureScheduledTasks
  if($global:ttTestEnabled -contains 'TTiTTulares Local' -or $global:ttTestEnabled -notcontains 'TTendencias Local'){throw 'Project-specific headline retirement failed'}
  New-Item -ItemType File -Path $TrendsV1RetiredFlag | Out-Null
  $global:ttTestEnabled=@();EnsureScheduledTasks
  foreach($name in @('TT Chrome Auto','SeLoRecordamos-Search','SeLoRecordamos-Published','SeLoRecordamos-Watchdog')){
    if($global:ttTestEnabled -notcontains $name){throw ('Shared task not preserved: '+$name)}
  }
  if($global:ttTestEnabled -contains 'TTiTTulares Local' -or $global:ttTestEnabled -contains 'TTendencias Local'){throw 'Retired task reenabled'}
  foreach($name in @('TTiTTularesDedicatedListener.ps1','TTendenciasDedicatedListener.ps1','TT-AutoUpdater.ps1')){
    $path=Join-Path $BaseDir $name
    if(-not (Test-TTV1ScriptRetired $path)){throw ('Missing retired script: '+$name)}
    [void](StartHiddenPs $path 'fixture');EnsureSingle '*fixture*' $path 'fixture';EnsureStartup 'fixture.cmd' $path
  }
  foreach($name in @('TT-LocalWatchdog.ps1','TT-Guard9223.ps1','selorecordamos.ps1')){
    if(Test-TTV1ScriptRetired (Join-Path $BaseDir $name)){throw ('Shared script marked retired: '+$name)}
  }
  EnsureTTitRequestedImageRecovery;EnsureRemoteTelegramHeal
  $script:ReconnectPending=$true;$script:LastReconnectAt=[DateTimeOffset]::MinValue
  Recover-ListenersAfterReconnect
  [IO.File]::WriteAllText((Join-Path $BaseDir 'TT-Editorial-Guard.js'),'TOO_MANY_TABS_HARD_CAP')
  $script:EditorialWakeCheckedAt=[DateTimeOffset]::MinValue
  EnsureEditorialScheduledWake
  if($global:ttTestStarts -or $global:ttTestStops -or $global:ttTestNetworkCalls -or $global:ttTestJobStarts){throw 'Retired V1 path executed a side effect'}

  # Verify restart selection separately; never stop/start real processes in CI.
  $watchdog='C:\TTiTTulares\TT-LocalWatchdog.ps1'
  foreach($command in @('powershell.exe -NoProfile -File "C:\TTiTTulares\TT-LocalWatchdog.ps1"','powershell.exe -File C:\TTiTTulares\TT-LocalWatchdog.ps1')){
    if(-not (Test-TTExactWatchdogProcess ([pscustomobject]@{ProcessId=987654;Name='powershell.exe';CommandLine=$command}) $watchdog)){throw 'Exact watchdog not recognized'}
  }
  foreach($command in @('powershell.exe -File C:\TTiTTulares\TT-Guard9223.ps1','powershell.exe -File C:\TTiTTulares\TT-LocalWatchdog.ps1.bak','powershell.exe -File C:\SeLoRecordamos\TT-LocalWatchdog.ps1')){
    if(Test-TTExactWatchdogProcess ([pscustomobject]@{ProcessId=987654;Name='powershell.exe';CommandLine=$command}) $watchdog){throw 'Shared/unknown process selected for restart'}
  }

  # Actual installer modifies only the temporary source file; restart is opt-in.
  $fixture=Join-Path $BaseDir 'TT-LocalWatchdog.ps1'
  [IO.File]::WriteAllText($fixture,$localHotfix,(New-Object Text.UTF8Encoding($false)))
  $output=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repair -BaseDir $BaseDir 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0 -or $output -notmatch 'GUARDIAS_INSTALADAS' -or $output -notmatch 'RECARGA=PENDIENTE'){throw 'Installer fixture failed'}
  if([IO.File]::ReadAllText($fixture) -cne $hotfixResult.source){throw 'Installed source differs or hotfix lost'}
  $backups=@(Get-ChildItem -LiteralPath $BaseDir -Directory -Filter 'Backup-Watchdog-V1-*')
  if($backups.Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $backups[0].FullName 'TT-LocalWatchdog.ps1')) -cne $localHotfix){throw 'Original local source backup missing'}
  Write-Output 'TT_V1_WATCHDOG_FLAGS_SHARED_CHROME_SLR_AND_EXACT_PATCH=PASS'
}finally{
  Remove-Variable ttTestEnabled -Scope Global -ErrorAction SilentlyContinue
  foreach($name in @('ttTestStarts','ttTestStops','ttTestNetworkCalls','ttTestJobStarts')){Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue}
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
