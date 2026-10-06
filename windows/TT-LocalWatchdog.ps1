# TT-LocalWatchdog.ps1
# Mantiene vivos listeners TT, auto-updater y Chrome CDP tras reinicios o caídas.
param([int]$IntervalSeconds=60)
$ErrorActionPreference="Continue"
$BaseDir="C:\TTiTTulares"
$LogPath=Join-Path $BaseDir "tt-local-watchdog.log"
$StartupDir=[Environment]::GetFolderPath("Startup")

try{
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TTKeepAwake {
  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint esFlags);
}
"@ -ErrorAction SilentlyContinue
  [void][TTKeepAwake]::SetThreadExecutionState(0x80000001)
}catch{}

$mutex=New-Object System.Threading.Mutex($false,"Local\TTAutomationWatchdog")
$owned=$false
try{$owned=$mutex.WaitOne(0,$false)}catch{}
if(-not $owned){exit 0}

function Log([string]$Text){
  try{
    New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
    Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss")+" "+$Text) -Encoding UTF8
  }catch{}
}
function PsProcs([string]$Pattern){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and [string]$_.CommandLine -like $Pattern
  })
}
function StartHiddenPs([string]$Script,[string]$Tag){
  if(-not (Test-Path -LiteralPath $Script)){Log "MISSING $Tag :: $Script";return $null}
  try{
    $out=Join-Path $BaseDir ($Tag+".watchdog.out.log")
    $err=Join-Path $BaseDir ($Tag+".watchdog.err.log")
    $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Script) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    Start-Sleep -Milliseconds 800
    $p.Refresh()
    if($p.HasExited){Log "START FAILED $Tag exit=$($p.ExitCode)";return $null}
    Log "STARTED $Tag pid=$($p.Id)"
    return $p
  }catch{Log "START ERROR $Tag :: $($_.Exception.Message)";return $null}
}
function EnsureSingle([string]$Pattern,[string]$Script,[string]$Tag){
  $rows=@(PsProcs $Pattern)
  if($rows.Count -eq 0){[void](StartHiddenPs $Script $Tag);return}
  if($rows.Count -gt 1){
    $keep=$rows|Sort-Object CreationDate -Descending|Select-Object -First 1
    foreach($p in $rows){if($p.ProcessId -ne $keep.ProcessId){try{Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}}
    Log "DEDUP $Tag keep=$($keep.ProcessId) removed=$($rows.Count-1)"
  }
}
function EnsureStartup([string]$Name,[string]$Script){
  try{
    if(-not $StartupDir){return}
    $path=Join-Path $StartupDir $Name
    $content='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Script+'"'
    if(-not (Test-Path $path) -or (Get-Content $path -Raw -ErrorAction SilentlyContinue) -ne $content){
      Set-Content -LiteralPath $path -Value $content -Encoding ASCII
      Log "STARTUP ENSURED $Name"
    }
  }catch{Log "STARTUP ERROR $Name :: $($_.Exception.Message)"}
}
function EnsureChrome{
  $ok=$false
  try{
    $r=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -TimeoutSec 3
    $ok=Boolean($r.webSocketDebuggerUrl)
  }catch{}
  if($ok){return}
  try{
    & schtasks.exe /Query /TN "TT Chrome Auto" 1>$null 2>$null
    if($LASTEXITCODE -eq 0){
      & schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
      Log "CHROME AUTO REQUESTED"
    }else{Log "CHROME TASK MISSING"}
  }catch{Log "CHROME AUTO ERROR :: $($_.Exception.Message)"}
}
$script:LastQueueRestart=@{ttittulares=[DateTimeOffset]::MinValue;ttendencias=[DateTimeOffset]::MinValue}

function Read-RawJson([string]$Url){
  try{
    $u=$Url+$(if($Url.Contains("?")){"&"}else{"?"})+"t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return Invoke-RestMethod -Uri $u -Headers @{"Cache-Control"="no-cache";"User-Agent"="TT-LocalWatchdog-QueueHealth"} -TimeoutSec 12
  }catch{return $null}
}

function RestartListenerForQueue([string]$Project,[string]$Pattern,[string]$Script,[string]$Tag,[string]$Reason){
  $now=[DateTimeOffset]::UtcNow
  try{
    if(($now-$script:LastQueueRestart[$Project]).TotalMinutes -lt 5){return}
  }catch{}
  Log "QUEUE HEALTH RESTART $Project :: $Reason"
  @(PsProcs $Pattern)|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
  Start-Sleep -Milliseconds 700
  [void](StartHiddenPs $Script $Tag)
  $script:LastQueueRestart[$Project]=$now
}

function CheckImageQueueHealth([string]$Project,[string]$Branch,[string]$Prefix,[string]$Pattern,[string]$Script,[string]$Tag){
  try{
    $api=if($Project -eq "ttittulares"){
      "https://europapress-rss.vercel.app/api/ttittulares-run-status"
    }else{
      "https://europapress-rss.vercel.app/api/ttendencias-run-status"
    }
    $idx=Read-RawJson ($api+"?view=image-index")
    if(-not $idx -or -not $idx.jobs){return}
    $jobRef=@($idx.jobs)|Select-Object -Last 1
    if(-not $jobRef){return}
    $targetId=[string]$jobRef.target_id
    if(-not $targetId){return}
    $job=Read-RawJson ($api+"?view=image-job&id="+[uri]::EscapeDataString($targetId))
    if(-not $job){return}
    $st=([string]$job.status).ToUpperInvariant()
    if($st -ne "REQUESTED"){return}
    if($job.pc_picked_up_at){return}
    $at=[DateTimeOffset]::Parse([string]$job.requested_at)
    $age=([DateTimeOffset]::UtcNow-$at).TotalSeconds
    if($age -lt 120){return}
    RestartListenerForQueue $Project $Pattern $Script $Tag ("job="+[string]$job.command_id+" age_s="+[int]$age)
  }catch{
    Log "QUEUE HEALTH ERROR $Project :: $($_.Exception.Message)"
  }
}

function EnsureScheduledTasks{
  foreach($name in @(
    "TT Chrome Auto","TTiTTulares Local","TTendencias Local",
    "SeLoRecordamos-Telegram","SeLoRecordamos-Search","SeLoRecordamos-Published","SeLoRecordamos-Watchdog"
  )){
    try{
      $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
      if($task -and $task.State -eq "Disabled"){
        Enable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue|Out-Null
        Log "TASK ENABLED $name"
      }
    }catch{}
  }
  try{
    $slr=Get-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
    if($slr -and $slr.State -ne "Running"){
      Start-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
      Log "SLR TELEGRAM LISTENER REQUESTED"
    }
  }catch{}
}

$tt=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$tr=Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$up=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$self=Join-Path $BaseDir "TT-LocalWatchdog.ps1"
EnsureStartup "TT Automation Watchdog.cmd" $self
EnsureStartup "TTiTTulares Mobile Trigger Listener.cmd" $tt
EnsureStartup "TTendencias Mobile Trigger Listener.cmd" $tr
EnsureStartup "TT Auto Updater.cmd" $up

Log "WATCHDOG START pid=$PID interval=$IntervalSeconds"
try{
  while($true){
    EnsureSingle "*TTiTTularesDedicatedListener.ps1*" $tt "ttittulares-listener"
    EnsureSingle "*TTendenciasDedicatedListener.ps1*" $tr "ttendencias-listener"
    EnsureSingle "*TT-AutoUpdater.ps1*" $up "tt-auto-updater"
    EnsureScheduledTasks
    EnsureChrome
    CheckImageQueueHealth "ttittulares" "control/ttittulares-run-trigger-v2" "ttittulares" "*TTiTTularesDedicatedListener.ps1*" $tt "ttittulares-listener"
    CheckImageQueueHealth "ttendencias" "control/ttendencias-run-trigger" "trends" "*TTendenciasDedicatedListener.ps1*" $tr "ttendencias-listener"
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  try{if($owned){$mutex.ReleaseMutex()}}catch{}
  try{[void][TTKeepAwake]::SetThreadExecutionState(0x80000000)}catch{}
  try{$mutex.Dispose()}catch{}
}
