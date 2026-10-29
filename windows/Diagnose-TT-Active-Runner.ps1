#requires -Version 5.1
# Read-only: displays only safe process metadata and relevant lock status.
$ErrorActionPreference="Continue"
$base="C:\TTiTTulares"
Write-Output ("TT_ACTIVE_RUNNER_DIAG_V1 "+(Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$procs=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { [string]$_.CommandLine -match '(?i)(?:TTiTTulares|TTendencias)ImageBridge[.]js|[\\/]Ejecutar[.]js' })
foreach($p in $procs) {
  $cmd=[string]$p.CommandLine
  $kind=if($cmd -match 'TTiTTularesImageBridge[.]js'){'ttittulares-image'}elseif($cmd -match 'TTendenciasImageBridge[.]js'){'ttendencias-image'}else{'editorial-sender'}
  $start=try{[datetime]$p.CreationDate}catch{Get-Date}
  $age=[math]::Round(((Get-Date)-$start).TotalMinutes,1)
  $proc=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
  Write-Output ("RUNNER type={0} pid={1} age_min={2} private_MB={3}" -f $kind,$p.ProcessId,$age, $(if($proc){[math]::Round($proc.PrivateMemorySize64/1MB,1)}else{'?'}))
}
if($procs.Count -eq 0){Write-Output "RUNNER none"}
foreach($file in @("ttittulares-image-bridge.lock.json","ttendencias-image-bridge.lock.json")) {
  $path=Join-Path $base $file
  if(-not(Test-Path -LiteralPath $path)){Write-Output "LOCK $file absent";continue}
  try{
    $lock=Get-Content -Raw -Encoding UTF8 -LiteralPath $path|ConvertFrom-Json
    $pidText=[string]$lock.pid
    if(-not $pidText){$pidText=[string]$lock.process_id}
    $alive=$false

    if($pidText -match '^\d+$'){$alive=([bool](Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue))}
    Write-Output ("LOCK {0} pid={1} alive={2} command_id_present={3}" -f $file,$pidText,$alive,([bool]$lock.command_id))
  }catch{Write-Output "LOCK $file invalid_json"}
}
try{
  $r=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/list" -TimeoutSec 6
  $targets=@();foreach($item in $r){$targets+= $item}
  $pages=@($targets | Where-Object { $_.type -eq 'page' })
  Write-Output ("CDP_9223 pages="+$pages.Count+" targets="+$targets.Count)
}catch{Write-Output "CDP_9223 inaccessible"}
Write-Output "READ_ONLY_DONE no processes or tabs modified"
