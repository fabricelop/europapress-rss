#requires -Version 5.1
# Manual operation: opens the existing relay profile visibly for its owner.
# No messages, images, cookies, credentials or catalogs are read or changed.
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
 for($i=0;$i -lt 60;$i++){
  $busy=$false
  if(Test-Path -LiteralPath $lock){try{$owner=Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json;$busy=[bool](Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue)}catch{}}
  if(-not $busy){break}
  if($i -eq 59){throw 'El receptor sigue trabajando. No se detiene. Vuelve a ejecutar mas tarde.'}
  if($i -eq 0){Write-Host 'Esperando a que termine la lectura actual del receptor...'}
  Start-Sleep -Seconds 1
 }
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
 Write-Host 'Se abre una ventana MANUAL para completar la verificacion o iniciar sesion en ChatGPT.'
 Start-Process -FilePath $chrome -ArgumentList @('--remote-debugging-address=127.0.0.1','--remote-debugging-port=9234',('--user-data-dir="'+$ttRelayProfile+'"'),'--no-first-run','--no-default-browser-check','https://chatgpt.com/c/6ae9d467-b2f8-83eb-9eea-c8e020f48fad') | Out-Null
 Read-Host 'Completa tu mismo la verificacion. Cuando veas la conversacion, vuelve aqui y pulsa INTRO' | Out-Null
 Write-Host 'Se reactivan las tareas que estaban activadas. Puedes minimizar esa ventana de Chrome.'
 Write-Host 'Actualizar la bandeja tras el siguiente ciclo. No se ha generado ni aprobado ninguna imagen.'
} finally {
 foreach($name in $restore){Enable-ScheduledTask -TaskName $name | Out-Null}
 Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
}
