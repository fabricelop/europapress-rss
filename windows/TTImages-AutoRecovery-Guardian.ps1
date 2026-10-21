#requires -Version 5.1
<#
TTImages AutoRecovery v1 - guardian for the EXISTING capture v2.3.
Never edits capture, Telegram/bot, images, deduplication baseline or Chrome 9223.
Runs periodically, intervenes only after two distinct recent capture failures.
#>
param([switch]$SelfTest,[switch]$InspectOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$blockPattern='Visor ya abierto al iniciar|No hay exactamente una pesta'
function Test-RepeatedBlock([string[]]$lines,[datetimeoffset]$now){
  $times=New-Object System.Collections.Generic.List[datetimeoffset]
  foreach($line in $lines){
    $stamp=$null
    $message=''
    if($line -match '^(\S+)\s+DETENIDO CON SEGURIDAD:\s*(.*)$'){
      $stampText=[string]$matches[1];$message=[string]$matches[2]
      $parsed=[datetimeoffset]::MinValue
      if(-not [datetimeoffset]::TryParse($stampText,[ref]$parsed)){continue}
      if(($now-$parsed).TotalMinutes -lt 0 -or ($now-$parsed).TotalMinutes -gt 28){continue}
      if($message -match $blockPattern){$times.Add($parsed)}
    }elseif($line -match '^(\S+)\s+FIN CAPTURA:\s*guardados=([1-9]\d*)'){
      $parsed=[datetimeoffset]::MinValue
      if([datetimeoffset]::TryParse([string]$matches[1],[ref]$parsed)){
        if(($now-$parsed).TotalMinutes -ge 0 -and ($now-$parsed).TotalMinutes -le 28){
          $times.Clear()
        }
      }
    }
  }
  if($times.Count -lt 2){return $false}
  $recent=@($times|Select-Object -Unique)
  return ($recent.Count -ge 2)
}
if($SelfTest){
  $now=[datetimeoffset]::UtcNow
  $a=$now.AddMinutes(-13).ToString('o')
  $b=$now.AddMinutes(-8).ToString('o')
  $c=$now.AddMinutes(-4).ToString('o')
  $twice=@("$a DETENIDO CON SEGURIDAD: Visor ya abierto al iniciar; se evita descargar la foto equivocada",
    "$b DETENIDO CON SEGURIDAD: No hay exactamente una pestana /images (pagina no disponible)")
  if(-not(Test-RepeatedBlock $twice $now)){throw 'SELFTEST: two blocks must activate recovery'}
  if(Test-RepeatedBlock @($twice[0]) $now){throw 'SELFTEST: one failure must not activate'}
  $ok=@($twice[0],"$b FIN CAPTURA: guardados=4; duplicados=0", "$c DETENIDO CON SEGURIDAD: Visor ya abierto al iniciar")
  if(Test-RepeatedBlock $ok $now){throw 'SELFTEST: a successful capture resets consecutive failures'}
  if(Test-RepeatedBlock @("$($now.AddMinutes(-90).ToString('o')) DETENIDO CON SEGURIDAD: Visor ya abierto al iniciar",
    $twice[1]) $now){throw 'SELFTEST: an old failure must not count'}
  # Return a pipeline value so the installer can verify it (Write-Host is not captured).
  Write-Output 'TTIMAGES_AUTORECOVERY_SELFTEST_OK'
  return
}
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
$report=Join-Path $root 'informe-captura-v2.json'
$log=Join-Path $root 'auto-recovery-v1.log'
$stateFile=Join-Path $root 'auto-recovery-v1-state.json'
$captureLog=Join-Path $root 'relay-captura-v2.log'
$recovery=Join-Path $PSScriptRoot 'Recuperar-TTImages-Visor-Bloqueado.ps1'
$taskName='TT Image Relay - Telegram v2'
function Note([string]$line){
  $msg=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')+' '+$line
  Write-Host ('TTIMAGES_AUTORECOVERY '+$line)
  try{Add-Content -LiteralPath $log -Value $msg -Encoding UTF8 -ErrorAction Stop}catch{}
}
$mutex=[System.Threading.Mutex]::new($false,'Local\TTImages_AutoRecovery_9234')
$acquired=$false
try {
  try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
  if(-not $acquired){return}
  if(-not(Test-Path -LiteralPath $report) -or -not(Test-Path -LiteralPath $captureLog) -or
     -not(Test-Path -LiteralPath $recovery)){Note 'SKIP files missing';return}
  $now=[datetimeoffset]::Now
  $file=Get-Item -LiteralPath $report
  $age=($now-[datetimeoffset]$file.LastWriteTime).TotalMinutes
  if($age -lt 0 -or $age -gt 12){return}
  $capture=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
  $reason=[string]$capture.error
  if($reason -notmatch $blockPattern){return}
  $lines=@(Get-Content -LiteralPath $captureLog -Tail 220 -Encoding UTF8 -ErrorAction Stop)
  if(-not(Test-RepeatedBlock $lines $now)){
    if($InspectOnly){Note ('PENDING one recent failure; report='+$reason)}
    return
  }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if($task.State -ne 'Ready'){Note ('SKIP capture task '+$task.State);return}
  $processes=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    $_.Name -match '^node(?:\.exe)?$' -and
    [string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)'
  })
  if($processes.Count){Note 'SKIP capture in progress';return}
  $health=Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/version' -TimeoutSec 5 -ErrorAction Stop
  if([string]$health.Browser -notmatch '^Chrome/'){Note 'SKIP Chrome 9234 not identified';return}
  $previous=$null
  if(Test-Path -LiteralPath $stateFile){
    try{$previous=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  }
  $last=[datetimeoffset]::MinValue
  if($previous -and $previous.at){
    [void][datetimeoffset]::TryParse([string]$previous.at,[ref]$last)
  }
  # Back off after every attempt. Failures require inspection, not looping.
  if(($now-$last).TotalMinutes -lt 30){
    if($InspectOnly){Note 'SKIP cooldown active (30 min)'}
    return
  }
  if($InspectOnly){Note ('READY_TO_RECOVER reason='+$reason);return}
  $state=@{at=$now.ToString('o');result='started';report_mtime=$file.LastWriteTimeUtc.ToString('o')}
  $state|ConvertTo-Json -Compress|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Note ('RECOVERY_ATTEMPT after consecutive capture failures: '+$reason)
  $output=''
  $exit=0
  try{
    # Invoke the recovery within the same hidden PowerShell host.
    # Spawning another powershell.exe can briefly flash a visible console.
    $allOutput=& $recovery -NoTaskStart 2>&1
    $exit=if($?){0}else{1}
    $output=($allOutput|Out-String)
  }catch{
    $exit=1
    $output=[string]$_.Exception.Message
  }
  $ok=($exit -eq 0 -and $output.Contains('RECUPERACION_HTTP_OK'))
  if($ok){
    $state.result='recovered'
    Note 'RECOVERY_OK; next regular capture cycle will pick up pending images'
  }else{
    $state.result='not_confirmed'
    $details=($output -split "\r?\n"|Where-Object{$_ -match 'RECUPERACION_DETENIDA|SIN_ACCION|GALERIA|No se'}|Select-Object -Last 2) -join '; '
    if($details.Length -gt 200){$details=$details.Substring(0,200)}
    Note ('RECOVERY_NOT_CONFIRMED exit='+$exit+' '+$details)
  }
  $state|ConvertTo-Json -Compress|Set-Content -LiteralPath $stateFile -Encoding UTF8
}catch{
  Note ('GUARDIAN_ERROR '+$_.Exception.Message)
}finally{
  if($acquired){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
