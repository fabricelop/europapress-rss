#requires -Version 5.1
# Manual operation: opens the existing relay profile visibly for its owner.
# No messages, images, cookies, credentials or catalogs are read or changed.
param(
 [ValidateRange(60,1800)][int]$ReceiverWaitSeconds = 600
)
$ErrorActionPreference='Stop'
$ttRelayProfile=Join-Path $env:LOCALAPPDATA 'TTImageRelay\ChromeProfile'
if(-not(Test-Path -LiteralPath $ttRelayProfile)){throw 'No existe el perfil del relay. Sin cambios.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$paths=@((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
$chrome=$paths | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(-not $chrome){throw 'Chrome no localizado. Sin cambios.'}
$taskNames=@('TT Actualidad - Relay 9234 oculto','TT Actualidad - Imagenes pendientes APP')
$stateFile='C:\TTiTTulares\relay-manual-task-state.json'
$restore=@()
if(Test-Path -LiteralPath $stateFile){$restore=@((Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).restore | Where-Object {$_ -in $taskNames})}
else {
 foreach($name in $taskNames){$task=Get-ScheduledTask -TaskName $name -ErrorAction Stop;if($task.State -ne 'Disabled'){$restore+=$name}}
 @{restore=$restore} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
}
try {
 foreach($name in $restore){Disable-ScheduledTask -TaskName $name | Out-Null}
 $lock='C:\TTiTTulares\image-approval-receipts\receiver.lock'
 # Disable future starts first, then let an already-running receiver finish.
 # An arbitrary live PID is not proof that it is still our Node receiver.
 function Get-ReceiverOwner {
  if(-not(Test-Path -LiteralPath $lock)){return $null}
  try {
   $owner=Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
   $ownerPid=[int]$owner.pid
   $lockAt=[double]$owner.at
   if($ownerPid -le 0 -or $lockAt -le 0){throw 'INVALID_LOCK'}
  } catch {throw 'receiver.lock no tiene una identidad valida; se conserva y no se cierra Chrome.'}
  $process=Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction Stop
  if(-not $process){return $null}
  $command=[string]$process.CommandLine
  if([string]$process.Name -notmatch '^node(?:\.exe)?$' -or
     $command -notmatch 'TTImageApprovalReceiver\.cjs'){
   throw "receiver.lock apunta al PID $ownerPid, pero no es el receptor Node esperado. Se conserva el bloqueo; revisar sin finalizar procesos."
  }
  try {$startMs=([DateTimeOffset]::new([datetime]$process.CreationDate)).ToUnixTimeMilliseconds()}
  catch {throw 'No se puede validar el inicio del receptor; no se toca Chrome.'}
  if($lockAt -lt ($startMs-10000) -or $lockAt -gt ($startMs+120000)){
   throw "receiver.lock apunta al PID $ownerPid con una fecha incoherente. Posible PID reutilizado; no se toca Chrome."
  }
  return @{Pid=$ownerPid;Started=[datetime]$process.CreationDate}
 }
 $freeChecks=0
 for($i=0;$i -lt $ReceiverWaitSeconds;$i++){
  $reader=Get-ReceiverOwner
  if($null -eq $reader){
   $freeChecks++
   if($freeChecks -ge 2){break}
  } else {
   $freeChecks=0
   if($i -eq 0 -or $i % 30 -eq 0){
    Write-Host ("Receptor Node PID {0} activo (inicio {1:HH:mm:ss}). Esperando sin detenerlo... {2}/{3} s" -f $reader.Pid,$reader.Started,$i,$ReceiverWaitSeconds)
   }
  }
  if($i -eq ($ReceiverWaitSeconds-1)){
   throw "El receptor sigue activo o el bloqueo no se estabiliza tras $ReceiverWaitSeconds s. No se interrumpe. Revisar receiver-cycle.json y receiver-status.json."
  }
  Start-Sleep -Seconds 1
 }
 # Final identity check immediately before any browser handoff.
 if($null -ne (Get-ReceiverOwner)){throw 'Se ha iniciado otra lectura; no se cierra Chrome.'}
 $version=$null
 try{$version=Invoke-RestMethod 'http://127.0.0.1:9234/json/version' -TimeoutSec 3}catch{}
 if($version){
  $owned=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object {[string]$_.CommandLine -match '--remote-debugging-port=9234(?:\s|$)' -and ([string]$_.CommandLine).Contains($ttRelayProfile)})
  if(-not $owned.Count){throw 'No se puede confirmar el perfil del navegador 9234. No se cierra.'}
  if(@($owned | Where-Object {[string]$_.CommandLine -match '--headless'}).Count){
   # Graceful close of this verified relay browser only, no forced termination; generator untouched.
   $close=@'
(async()=>{const r=await fetch('http://127.0.0.1:9234/json/version');const v=await r.json();const u=new URL(v.webSocketDebuggerUrl);if(u.hostname!=='127.0.0.1'&&u.hostname!=='localhost')throw Error('NOT_LOCAL');if(u.port!=='9234')throw Error('WRONG_PORT');const w=new WebSocket(u);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error('TIMEOUT')),5000);w.addEventListener('open',()=>{clearTimeout(t);ok()},{once:true});w.addEventListener('error',()=>bad(Error('CONNECT')),{once:true})});w.send(JSON.stringify({id:1,method:'Browser.close',params:{}}));await new Promise(ok=>{const t=setTimeout(ok,1500);w.addEventListener('close',()=>{clearTimeout(t);ok()},{once:true})});w.close()})().catch(()=>{console.error('No se pudo cerrar el relay de forma ordenada');process.exitCode=1});
'@
   & $node -e $close
   if($LASTEXITCODE -ne 0){throw 'Cierre no confirmado. Sin abrir otro navegador.'}
   for($i=0;$i -lt 10;$i++){$available=$false;try{Invoke-RestMethod 'http://127.0.0.1:9234/json/version' -TimeoutSec 1 | Out-Null;$available=$true}catch{};if(-not $available){break};Start-Sleep -Milliseconds 500}
   if($available){throw 'El relay aun no ha cerrado. No se fuerza.'}
  }
 }
 # A past command conversation may have been deleted, revoked or belong to a different account.
 # The manual handoff only needs the signed-in ChatGPT entry point; the receiver
 # independently validates exact task conversations, without creating chat messages.
 Write-Host 'Se abre ChatGPT en el perfil del relay para verificar la sesion manualmente.'
 Start-Process -FilePath $chrome -ArgumentList @('--remote-debugging-address=127.0.0.1','--remote-debugging-port=9234',('--user-data-dir="'+$ttRelayProfile+'"'),'--no-first-run','--no-default-browser-check','https://chatgpt.com/') | Out-Null
 Read-Host 'Comprueba que ChatGPT abre y, si deseas, entra en una conversacion propia desde la barra lateral. Despues pulsa INTRO' | Out-Null
 Write-Host 'Se reactivan las tareas que estaban activadas. Puedes minimizar esa ventana de Chrome.'
 Write-Host 'Actualizar la bandeja tras el siguiente ciclo. No se ha generado ni aprobado ninguna imagen.'
} finally {
 # Keep the recovery state file if ANY task could not be restored.
 $restoreFailed=$false
 foreach($name in $restore){
  try {Enable-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null}
  catch {$restoreFailed=$true;Write-Warning ("No se pudo restaurar la tarea: "+$name)}
 }
 if(-not $restoreFailed){Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue}
 else {Write-Warning ("Estado de recuperacion conservado en "+$stateFile)}
}
