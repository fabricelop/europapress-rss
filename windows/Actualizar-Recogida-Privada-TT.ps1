#requires -Version 5.1
param([ValidateRange(10,3600)][int]$MaxWaitSeconds=900)
# Incremental, hash-pinned repair of the original-image receiver for the iPhone APP.
# Do not replace generator bridges, secrets, Site, or other scheduled tasks.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='3a16f683d2d956eafa0763dc7997d9060e03453a'
$files=@{
 'TTendenciasWebImages.cjs'='12fa8a80d176003a7ae6a8f888ef831dd867c9e6e12027ee3d6d0568d08af65a'
 'TTiTTularesWebImages.cjs'='0a9c830dec48364ebddde76ca2796c25647315f4df5390d5645661522cf3fae5'
 'TTImageApprovalReceiver.cjs'='ec901721718b3be8192e583ad92c50961c6faf0c7a8d9aa78eab42e331f761b9'
}
# Only documented pre-repair releases or the target version may be replaced.
# A local custom version stops installation rather than silently deleting it.
$allowed=@{
 'TTendenciasWebImages.cjs'=@(
  '595425bcb143776ae378a7d7a5e37bdabe0aa496631da39a9214adadb3580774',
  '8b920e1b2034f1ee18c544ed15f16ca4d58d4c2c6b8422406af15ac66f9c6d01',
  $files['TTendenciasWebImages.cjs'])
 'TTiTTularesWebImages.cjs'=@(
  '8ef3c4c1da5e4dfa0556c1f83e2db8e3f862a1ff028a168199dd562553e0467c',
  '8e7142b10da30f16db84dcd335cc92392a32a4736cd70480ffd99cb981a66e7b',
  $files['TTiTTularesWebImages.cjs'])
 'TTImageApprovalReceiver.cjs'=@(
  '1299dbaabdd856cdd773cea71ed280c7dea5c34b67fc6d02601d1c32ed7eae58',
  'af14c45846e3d41298522146326f25e9f1ff43061649df3688568f3793cb2083',
  'fdcfe30087edae8ac68db35e201e2058d22cf0371e07adfe3a7697730145df38',
  '03b178e4a6b83a95faa6efcc525ac3673768fbd022f7280d2995ef72560940a4',
  '12ab6cf5bf2c54dc0d821d47e05ec39b25340d492734d9385497de72fc600076',
  '1788962e76fce00891f74027afba349f82d195e94ac8c2e06929cfdf2fa1bd37',
  $files['TTImageApprovalReceiver.cjs'])
}
function Get-BusyImageProcesses {
 @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
   Where-Object {[string]$_.CommandLine -match '(?i)TT(endencias|iTTulares)ImageBridge\.js|TTImageApprovalReceiver\.cjs'})
}
function Assert-Idle {
 if(@(Get-BusyImageProcesses).Count){
  throw 'Ha empezado otro encargo mientras se preparaba la instalacion. Ningun proceso se detiene.'
 }
}
# Pause only the existing private-inbox scheduler, never the generators,
# listeners, Chrome, or any other task. Running jobs are allowed to finish.
# Restore the original enabled state in finally even if installation fails.
function Wait-ForIdle([int]$limitSeconds) {
 $deadline=(Get-Date).AddSeconds($limitSeconds)
 $lastNotice=[datetime]::MinValue
 while($true){
  $busy=@(Get-BusyImageProcesses)
  if(-not $busy.Count){ return }
  if((Get-Date) -ge $deadline){
   $n=($busy | ForEach-Object {$_.ProcessId}) -join ','
   throw ('Todavia hay encargos activos (PID '+$n+'). No se ha interrumpido ninguno ni instalado archivos. Repite cuando terminen.')
  }
  if(((Get-Date)-$lastNotice).TotalSeconds -ge 30){
   $types=($busy | ForEach-Object {if($_.CommandLine -match 'TTImageApprovalReceiver'){'receptor privado'}else{'generador'}} | Select-Object -Unique) -join ' y '
   Write-Host ('Actualizacion protegida: '+$types+' aun activo. Continuara automaticamente al quedar libre.')
   $lastNotice=Get-Date
  }
  Start-Sleep -Seconds 5
 }
}
if(-not(Test-Path -LiteralPath $base -PathType Container)){throw 'No existe C:\TTiTTulares; sin cambios.'}
foreach($name in @('TTendenciasImageBridge.js','TTiTTularesImageBridge.js')){
 if(-not(Test-Path -LiteralPath (Join-Path $base $name))){throw ('Falta el bridge existente: '+$name)}
}
$task=Get-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -ErrorAction Stop
if(-not @($task.Actions | Where-Object {[IO.Path]::GetFileName($_.Execute) -eq 'wscript.exe'}).Count){
 throw 'La tarea de imagenes pendientes debe conservar su lanzador oculto; sin cambios.'
}
$node=(Get-Command node.exe -ErrorAction Stop).Source
foreach($name in $files.Keys){
 $local=Join-Path $base $name
 if(-not(Test-Path -LiteralPath $local)){throw ('Falta '+$name+'; sin cambios.')}
 $current=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
 if($allowed[$name] -notcontains $current){throw ('Version local no reconocida: '+$name+' ('+$current+'). No se sobrescribe.')}
}
foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')){
 $text=[IO.File]::ReadAllText((Join-Path $base $name))
 if(-not $text.Contains("return {status:'waiting',reason:'manual_approval_required'}")){
  throw ('El bridge no tiene la pausa de aprobacion: '+$name)
 }
}
# Download and verify before waiting; no running processes have been changed.
$temp=Join-Path $env:TEMP ('TT-PrivateInboxPatch-'+[guid]::NewGuid().ToString('N'))
$backup=Join-Path $base ('private-inbox-backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$written=@()
$receiverPaused=$false
$installed=$false
try{
 foreach($name in $files.Keys){
  $destination=Join-Path $temp $name
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'+$name) -OutFile $destination -TimeoutSec 60
  if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $files[$name]){throw ('SHA invalido: '+$name)}
  & $node --check $destination
  if($LASTEXITCODE -ne 0){throw ('Sintaxis JS invalida: '+$name)}
 }
 foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')){
  if(-not([IO.File]::ReadAllText((Join-Path $temp $name)).Contains("return {status:'waiting',reason:'manual_approval_required'}"))){
   throw ('La version nueva no conserva la pausa editorial: '+$name)
  }
 }
 # Temporarily stop only future launches of the private inbox receiver.
 # The current receiver and both generator bridges remain entirely untouched.
 if((Get-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop).State -ne 'Disabled'){
  try {
   Disable-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop | Out-Null
   $receiverPaused=$true
   Write-Host 'Lanzamientos del receptor pausados temporalmente; los trabajos activos siguen.'
  } catch {
   Write-Warning 'Sin permiso para pausar la tarea privada. Se esperara una ventana de inactividad sin detener nada.'
  }
 }
 Wait-ForIdle $MaxWaitSeconds
 Assert-Idle
 New-Item -ItemType Directory -Path $backup | Out-Null
 foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $base $name) -Destination (Join-Path $backup $name)}
 foreach($name in $files.Keys){
  Copy-Item -LiteralPath (Join-Path $temp $name) -Destination (Join-Path $base $name) -Force
  $written+=$name
 }
 Write-Host 'Receptor privado de imagenes actualizado y hashes verificados. NO se ha cambiado la APP ni el Site.' -ForegroundColor Green
 Write-Host 'JPEG/WebP se convertiran a PNG solo para el buzón; reintentos recuperan originales sin generar otros.'
 Write-Host 'La tarea programada se conserva. La confirmacion de recepcion requiere ver un recibo PRIVATE_INBOX RECEIVED_pending.'
 Write-Host ('Copia de seguridad: '+$backup)
 $installed=$true
}catch{
 foreach($name in $written){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $base $name) -Force}
 throw
}finally{
 # Always restore the receiver's prior scheduled state: no forgotten pause.
 $enableFailure=$null
 if($receiverPaused){
  try {Enable-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop | Out-Null}
  catch {$enableFailure=$_.Exception.Message}
 }
 Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
 if($enableFailure){throw ('ATENCION: no se pudo reactivar la tarea privada: '+$enableFailure)}
 if($installed -and $receiverPaused){
  try {
   Start-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
   Write-Host 'Receptor privado reactivado; se ha solicitado un ciclo de recogida.'
  }catch{Write-Warning 'La instalacion termino, pero no se pudo lanzar un ciclo inmediato. La programacion original sigue activa.'}
 }
}
