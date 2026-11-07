#requires -Version 5.1
param([ValidateRange(10,3600)][int]$MaxWaitSeconds=900)
# Incremental, hash-pinned repair of the original-image receiver for the iPhone APP.
# Do not replace generator bridges, secrets, Site, or other scheduled tasks.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='723c4c89b6b3b8f49bff51432437fdbc97e7207c'
$files=@{
 'TTendenciasWebImages.cjs'='4f2f00db3aa3794e1c293201fc9f32e6f6dcd4cacc27c7742da0db93d9292e3f'
 'TTiTTularesWebImages.cjs'='7b7bc8d6e4e9a84e47714528df3cbe19e1feae7b11286712dd76d587396f707b'
 'TTImageApprovalReceiver.cjs'='5e4105171a9f27a42f619ce3fba7d912c2e5abf50a5fb7828e571491b2d9805a'
}
# Only documented pre-repair releases or the target version may be replaced.
# A local custom version stops installation rather than silently deleting it.
$allowed=@{
 'TTendenciasWebImages.cjs'=@(
  '595425bcb143776ae378a7d7a5e37bdabe0aa496631da39a9214adadb3580774',
  '8b920e1b2034f1ee18c544ed15f16ca4d58d4c2c6b8422406af15ac66f9c6d01',
  '12fa8a80d176003a7ae6a8f888ef831dd867c9e6e12027ee3d6d0568d08af65a',
  $files['TTendenciasWebImages.cjs'])
 'TTiTTularesWebImages.cjs'=@(
  '8ef3c4c1da5e4dfa0556c1f83e2db8e3f862a1ff028a168199dd562553e0467c',
  '8e7142b10da30f16db84dcd335cc92392a32a4736cd70480ffd99cb981a66e7b',
  '0a9c830dec48364ebddde76ca2796c25647315f4df5390d5645661522cf3fae5',
  $files['TTiTTularesWebImages.cjs'])
 'TTImageApprovalReceiver.cjs'=@(
  '1299dbaabdd856cdd773cea71ed280c7dea5c34b67fc6d02601d1c32ed7eae58',
  'af14c45846e3d41298522146326f25e9f1ff43061649df3688568f3793cb2083',
  'fdcfe30087edae8ac68db35e201e2058d22cf0371e07adfe3a7697730145df38',
  '03b178e4a6b83a95faa6efcc525ac3673768fbd022f7280d2995ef72560940a4',
  '12ab6cf5bf2c54dc0d821d47e05ec39b25340d492734d9385497de72fc600076',
  '1788962e76fce00891f74027afba349f82d195e94ac8c2e06929cfdf2fa1bd37',
  'ec901721718b3be8192e583ad92c50961c6faf0c7a8d9aa78eab42e331f761b9',
  '55bcd5d89eefbe18ebe19c7014f5301e80b976e96365e5551a2fa3ac380ddf9e',
  '7d7791edded824e6d7adf0fa8838a26e60c01392416fa43a2f06f246b095c48a',
  $files['TTImageApprovalReceiver.cjs'])
}
# Generators must finish first: do not interrupt their CDP sessions.
# The receiver is a one-shot Node process: its already-loaded modules continue
# in memory while an atomic on-disk replacement prepares the NEXT cycle.
function Get-BusyGenerators {
 @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object {[string]$_.CommandLine -match '(?i)TT(endencias|iTTulares)ImageBridge\.js'})
}
function Assert-GeneratorsIdle {
 if(@(Get-BusyGenerators).Count){
  throw 'Ha empezado otra generacion durante la sustitucion. Ningun proceso se interrumpe.'
 }
}
function Wait-ForGeneratorsIdle([int]$limitSeconds) {
 $deadline=(Get-Date).AddSeconds($limitSeconds)
 $lastNotice=[datetime]::MinValue
 while($true){
  $busy=@(Get-BusyGenerators)
  if(-not $busy.Count){return}
  if((Get-Date) -ge $deadline){
   $ids=($busy|ForEach-Object {$_.ProcessId}) -join ','
   throw ('Generadores activos (PID '+$ids+'). Sin cambios ni procesos detenidos. Vuelve a ejecutar el instalador mas tarde.')
  }
  if(((Get-Date)-$lastNotice).TotalSeconds -ge 30){
   Write-Host 'Preparacion completa. Se espera a que termine la generacion actual; no se cierra ni detiene nada.'
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
$stagedPaths=@()
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
 # Receiver may continue serving pending images from its in-memory modules.
 # Only an actual generator needs a quiet window. No scheduled task is disabled.
 Wait-ForGeneratorsIdle $MaxWaitSeconds
 Assert-GeneratorsIdle
 # Stage every replacement on the SAME volume as the live scripts so that
 # File.Replace is atomic: an active receiver sees complete old/new source,
 # never an interrupted Copy-Item or partially written JavaScript file.
 New-Item -ItemType Directory -Path $backup | Out-Null
 foreach($name in $files.Keys) {
  $stage=Join-Path $base ('.'+$name+'.stage-'+[guid]::NewGuid().ToString('N'))
  Copy-Item -LiteralPath (Join-Path $temp $name) -Destination $stage -Force
  $stagedPaths+= $stage
  if((Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash.ToLowerInvariant() -ne $files[$name]) {
   throw ('Archivo preparado invalido: '+$name)
  }
 }
 foreach($name in $files.Keys) {
  Assert-GeneratorsIdle
  $live=Join-Path $base $name
  $stage=@($stagedPaths | Where-Object { [IO.Path]::GetFileName($_) -like ('.'+$name+'.stage-*') })[0]
  if(-not $stage){ throw ('Falta archivo temporal: '+$name) }
  $old=(Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash.ToLowerInvariant()
  if($allowed[$name] -notcontains $old){throw ('Version local ha cambiado: '+$name)}
  [IO.File]::Replace($stage,$live,(Join-Path $backup $name),$true)
  $written+= $name
  if((Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash.ToLowerInvariant() -ne $files[$name]){
   throw ('No coincide el SHA tras reemplazar: '+$name)
  }
 }
 Write-Host 'Receptor privado de imagenes actualizado y hashes verificados. NO se ha cambiado la APP ni el Site.' -ForegroundColor Green
 Write-Host 'Sin corte de fecha, ni ocho por ciclo, ni caducidad a 72 h de originales pendientes.'
 Write-Host 'JPEG/WebP se convertiran a PNG solo para el buzón; reintentos recuperan originales sin generar otros.'
 Write-Host 'La tarea programada se conserva. La confirmacion de recepcion requiere ver un recibo PRIVATE_INBOX RECEIVED_pending.'
 Write-Host ('Copia de seguridad: '+$backup)
 $installed=$true
}catch{
 foreach($name in $written){
  $live=Join-Path $base $name
  $old=Join-Path $backup $name
  if(Test-Path -LiteralPath $old){
   # Atomic rollback, also safe if the one-shot receiver is still running.
   $restore=Join-Path $base ('.'+$name+'.restore-'+[guid]::NewGuid().ToString('N'))
   try {
    Copy-Item -LiteralPath $old -Destination $restore -Force
    [IO.File]::Replace($restore,$live,$null,$true)
   }finally{Remove-Item -LiteralPath $restore -Force -ErrorAction SilentlyContinue}
  }
 }
 throw
}finally{
 foreach($stage in $stagedPaths){
  Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
 }
 Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
