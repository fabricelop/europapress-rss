#requires -Version 5.1
# Regression for TTImages installer on ACTUAL Windows PowerShell 5.1.
# All scheduled task and HTTP commands are mocked: NO REAL TASK IS INSTALLED.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path '.').Path
$installer=Join-Path $repo 'windows\Install-TTImages-AutoRecovery.ps1'
$fixture=Join-Path $env:TEMP ('TTImages-Installer-Test-'+[Guid]::NewGuid().ToString('N'))
$previousLocalAppData=$env:LOCALAPPDATA
$script:registered=$null
$script:realCaptureReads=0
try {
  New-Item -ItemType Directory -Path $fixture -Force|Out-Null
  $env:LOCALAPPDATA=$fixture
  $relayRoot=Join-Path $fixture 'TTImageRelay'
  New-Item -ItemType Directory -Path $relayRoot -Force|Out-Null
  '{}'|Set-Content -LiteralPath (Join-Path $relayRoot 'informe-captura-v2.json')
  function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    if($TaskName -eq 'TT Image Relay - Telegram v2'){
      $script:realCaptureReads++
      return [pscustomobject]@{State='Ready';Actions=@([pscustomobject]@{Execute='wscript.exe';Arguments='trusted-capture.vbs'})}
    }
    if($TaskName -eq 'TTImages - AutoRecovery Viewer'){
      return $script:registered
    }
    throw ('Unexpected scheduled task lookup '+$TaskName)
  }
  function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri,[int]$TimeoutSec)
    if($Uri -ne 'http://127.0.0.1:9234/json/version'){throw 'Unexpected HTTP '+$Uri}
    return [pscustomobject]@{Browser='Chrome/154.0.8037.98'}
  }
  function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing,[string]$Uri,[string]$OutFile,[int]$TimeoutSec)
    if($Uri -notmatch '/windows/(TTImages-AutoRecovery-Guardian|Recuperar-TTImages-Visor-Bloqueado)\.ps1$'){
      throw 'Unexpected URL'
    }
    $source=Join-Path $repo ('windows\'+$matches[1]+'.ps1')
    Copy-Item -LiteralPath $source -Destination $OutFile -ErrorAction Stop
  }
  function New-ScheduledTaskAction {
    [CmdletBinding()]
    param([string]$Execute,[string]$Argument,[string]$WorkingDirectory)
    return [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}
  }
  function New-ScheduledTaskTrigger {
    [CmdletBinding()]
    param([switch]$Once,[datetime]$At,[timespan]$RepetitionInterval,[timespan]$RepetitionDuration)
    if(-not $Once -or $RepetitionInterval.TotalMinutes -ne 15){throw 'Wrong guardian cadence'}
    return [pscustomobject]@{RepetitionInterval=$RepetitionInterval}
  }
  function New-ScheduledTaskPrincipal {
    [CmdletBinding()]
    param([string]$UserId,[string]$LogonType,[string]$RunLevel)
    return [pscustomobject]@{UserId=$UserId}
  }
  function New-ScheduledTaskSettingsSet {
    [CmdletBinding()]
    param([string]$MultipleInstances,[timespan]$ExecutionTimeLimit,
      [switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
    return [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit}
  }
  function Register-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName,$Action,$Trigger,$Principal,$Settings,
      [string]$Description,[switch]$Force)
    if($TaskName -ne 'TTImages - AutoRecovery Viewer'){throw 'Wrong task name'}
    if($Action.Execute -notmatch '(?i)wscript\.exe$'){throw 'Must use hidden wscript host'}
    if($Action.Arguments -notlike '*//B //Nologo*'){throw 'Wscript background flags missing'}
    if($Trigger.RepetitionInterval.TotalMinutes -ne 15){throw '15-minute cadence missing'}
    $script:registered=[pscustomobject]@{State='Ready';Actions=@($Action)}
    return $script:registered
  }
  # First verify that SelfTest passes WITHOUT creating anything.
  & $installer -PreflightOnly
  if($null -ne $script:registered){throw 'Preflight unexpectedly created a scheduled task'}
  # Then simulate the full install, still without real TaskScheduler APIs.
  & $installer
  if($null -eq $script:registered){throw 'Installer did not register mock guardian task'}
  if($script:realCaptureReads -lt 2){throw 'Original capture task status was not verified'}
  $dir=Join-Path $relayRoot 'AutoRecovery-v1'
  $launcher=Join-Path $dir 'TTImages-AutoRecovery-Hidden.vbs'
  if(-not(Test-Path $launcher)){throw 'Invisible launcher not written'}
  $vbs=Get-Content -LiteralPath $launcher -Raw
  if(-not $vbs.Contains('shell.Run command, 0, True')){throw 'Hidden VBS must wait for guardian'}
  if(-not $vbs.Contains('-WindowStyle Hidden')){throw 'Hidden PowerShell startup missing'}
  if(-not(Test-Path (Join-Path $dir 'TTImages-AutoRecovery-Guardian.ps1'))){
    throw 'Guardian source missing after installation'
  }
  Write-Host 'TTIMAGES_INSTALLER_WINDOWS_PS51_MOCK_INSTALL_OK'
} finally {
  $env:LOCALAPPDATA=$previousLocalAppData
  if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Force -Recurse -ErrorAction SilentlyContinue}
}
