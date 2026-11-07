#requires -Version 5.1
# Opt-in, fail-closed: replace only known TT watchdog versions and convert
# known visible .cmd startup wrappers into WScript-hosted invisible .vbs.
# No Chrome, Node, other watchdogs or scheduled tasks are stopped/restarted.
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$sourcePath=Join-Path $base 'TT-LocalWatchdog.ps1'
$pin='5b085688f4ed4fe8cefb8c704a2e3150ef5b3326'
$expected='f312cd9f795dc5fe408e14e10d4a675593fb3f7b9bd7156f53ec9326d58fae84'
$allowed=@(
 '87ad89e4a6646f7e2935d87250e89a432fea27fccfd2998537a804419355956f',
 $expected
)
function CanonicalHash([string]$file){
 $codec=New-Object System.Text.UTF8Encoding($false,$true)
 $source=[IO.File]::ReadAllText($file,$codec)
 $normalized=$source.Replace("`r`n","`n").Replace("`n","`r`n")
 $bytes=[Text.Encoding]::UTF8.GetBytes($normalized)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}
 finally{$sha.Dispose()}
}
if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){
 throw 'WATCHDOG_NOT_FOUND: no se modifica nada.'
}
$originalHash=CanonicalHash $sourcePath
if($allowed -notcontains $originalHash){
 throw ('WATCHDOG_LOCAL_VERSION_UNKNOWN '+$originalHash+'; no se sobrescribe.')
}
$temp=Join-Path $env:TEMP ('tt-watchdog-hidden-'+[guid]::NewGuid().ToString('N')+'.ps1')
$backup=Join-Path $base ('watchdog-hidden-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
 Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/TT-LocalWatchdog.ps1') -OutFile $temp -TimeoutSec 60
 if((CanonicalHash $temp) -ne $expected){throw 'WATCHDOG_REMOTE_SHA_INVALID'}
 $tokens=$null;$parseErrors=$null
 [Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$parseErrors)|Out-Null
 if($parseErrors.Count){throw ('WATCHDOG_PARSE_INVALID '+$parseErrors[0].Message)}
 if(-not ([IO.File]::ReadAllText($temp).Contains('TTActualidad hidden startup v2'))){
  throw 'WATCHDOG_HIDDEN_MARKER_MISSING'
 }
 $startDir=[Environment]::GetFolderPath('Startup')
 if(-not $startDir -or -not(Test-Path -LiteralPath $startDir)){throw 'STARTUP_DIRECTORY_MISSING'}
 $entries=@{
  'TT Automation Watchdog.cmd'='TT-LocalWatchdog.ps1'
  'TTiTTulares Mobile Trigger Listener.cmd'='TTiTTularesDedicatedListener.ps1'
  'TTendencias Mobile Trigger Listener.cmd'='TTendenciasDedicatedListener.ps1'
  'TT Auto Updater.cmd'='TT-AutoUpdater.ps1'
 }
 $convert=@()
 $preserved=@()
 foreach($entry in $entries.GetEnumerator()){
  $cmd=Join-Path $startDir $entry.Key
  if(-not (Test-Path -LiteralPath $cmd -PathType Leaf)){continue}
  $script=Join-Path $base $entry.Value
  if(-not(Test-Path -LiteralPath $script -PathType Leaf)){$preserved+=($entry.Key+': script absent');continue}
  $expectedCmd='@echo off'+"`n"+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$script+'"'
  $existing=[IO.File]::ReadAllText($cmd).Replace("`r`n","`n").TrimEnd("`r","`n")
  if($existing -cne $expectedCmd){$preserved+=($entry.Key+': script personalizado');continue}
  $hidden=[IO.Path]::ChangeExtension($cmd,'.vbs')
  if(Test-Path -LiteralPath $hidden){
   $old=[IO.File]::ReadAllText($hidden)
   if(-not (($old.Contains('TTActualidad hidden startup v1') -or
              $old.Contains('TTActualidad hidden startup v2')) -and
             $old.Contains($script) -and $old.Contains(',0,False'))){
    $preserved+=($entry.Key+': VBS desconocido');continue
   }
  }
  $convert+=@{cmd=$cmd;hidden=$hidden;script=$script;name=$entry.Key}
 }
 if($PreflightOnly){
  Write-Host ('PREFLIGHT_OK watcher_hash='+$originalHash+' convertibles='+$convert.Count+' preservados='+$preserved.Count)
  return
 }
 New-Item -ItemType Directory -Path $backup -Force|Out-Null
 if($originalHash -ne $expected){
  $stage=Join-Path $base ('.TT-LocalWatchdog.stage-'+[guid]::NewGuid().ToString('N')+'.ps1')
  try{
   Copy-Item -LiteralPath $temp -Destination $stage -Force
   if((CanonicalHash $stage) -ne $expected){throw 'WATCHDOG_STAGE_SHA_INVALID'}
   if((CanonicalHash $sourcePath) -ne $originalHash){throw 'WATCHDOG_CHANGED_DURING_INSTALL'}
   [IO.File]::Replace($stage,$sourcePath,(Join-Path $backup 'TT-LocalWatchdog.ps1'),$true)
  }finally{Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue}
  if((CanonicalHash $sourcePath) -ne $expected){throw 'WATCHDOG_INSTALLED_SHA_INVALID'}
 }
 $converted=0
 foreach($entry in $convert){
  # Never overwrite a foreign VBS. Existing verified v1/v2 wrappers remain.
  if(-not(Test-Path -LiteralPath $entry.hidden)){
   $command='powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$entry.script+'"'
   $vbs="' TTActualidad hidden startup v2"+[Environment]::NewLine+
     'CreateObject("WScript.Shell").Run "'+$command.Replace('"','""')+'",0,False'
   [IO.File]::WriteAllText($entry.hidden,$vbs,[Text.Encoding]::Unicode)
  }
  if(Test-Path -LiteralPath $entry.cmd){
   Copy-Item -LiteralPath $entry.cmd -Destination (Join-Path $backup $entry.name) -Force
   Move-Item -LiteralPath $entry.cmd -Destination ($entry.cmd+'.disabled-'+(Get-Date -Format 'yyyyMMddHHmmss')) -ErrorAction Stop
   $converted++
  }
 }
 Write-Host 'WATCHDOG_HIDDEN_OK: se actualizaron solo el fichero y los iniciadores reconocidos.'
 Write-Host ('Startup CMD desactivados='+$converted+'; personalizados conservados='+$preserved.Count)
 Write-Host 'No se ha parado Chrome, Node, ni el watchdog; no se ha reactivado ninguna tarea.'
 Write-Host ('Backup: '+$backup)
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
