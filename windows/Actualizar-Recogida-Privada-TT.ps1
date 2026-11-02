#requires -Version 5.1
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='ced56017a03551d3055b34f5deb39de216124a15'
$files=@{
 'TTendenciasImageBridge.js'='bce8c33c58fcf300cd2e8f2f48febf792a155ed930455afaa3809b8e34079ce6'
 'TTiTTularesImageBridge.js'='9cdcb6fce51bd7d89af4a1d0415fbaf5ff62c430838680a10c31d45be4b6670e'
 'TTImageApprovalReceiver.cjs'='03b178e4a6b83a95faa6efcc525ac3673768fbd022f7280d2995ef72560940a4'
}
function Assert-Idle {
 $busy=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {[string]$_.CommandLine -match '(?i)TT(endencias|iTTulares)ImageBridge\.js'})
 if($busy.Count){throw 'Hay generacion activa. No se interrumpe. Repite al terminar.'}
}
Assert-Idle
$allowed=@{
 'TTendenciasImageBridge.js'=@('416069b713104821be1a76c53f3cf332f647ff83331aa293c993ef21f84a3283','bce8c33c58fcf300cd2e8f2f48febf792a155ed930455afaa3809b8e34079ce6')
 'TTiTTularesImageBridge.js'=@('f5c2c3918184e10b4f9854191bed53bb4abf6fde76d69c1266067fdd27540851','9cdcb6fce51bd7d89af4a1d0415fbaf5ff62c430838680a10c31d45be4b6670e')
 'TTImageApprovalReceiver.cjs'=@('1299dbaabdd856cdd773cea71ed280c7dea5c34b67fc6d02601d1c32ed7eae58','af14c45846e3d41298522146326f25e9f1ff43061649df3688568f3793cb2083','fdcfe30087edae8ac68db35e201e2058d22cf0371e07adfe3a7697730145df38','03b178e4a6b83a95faa6efcc525ac3673768fbd022f7280d2995ef72560940a4')
}
foreach($name in $files.Keys){
 $local=Join-Path $base $name
 if(-not(Test-Path -LiteralPath $local)){throw ('Falta '+$name+'. Sin cambios.')}
 if($allowed[$name] -notcontains (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()){throw ('Version local no reconocida: '+$name+'. Se conserva, sin modificar.')}
}
foreach($name in @('TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs')){
 if(-not([IO.File]::ReadAllText((Join-Path $base $name)).Contains("return {status:'waiting',reason:'manual_approval_required'}"))){throw ('Falta pausa de asociacion en '+$name)}
}
$task=Get-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -ErrorAction Stop
if([IO.Path]::GetFileName($task.Actions.Execute) -ne 'wscript.exe'){throw 'La tarea debe usar el lanzador oculto. Sin cambios.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$temp=Join-Path $env:TEMP ('TT-PrivateBoth-'+[guid]::NewGuid().ToString('N'))
$backup=Join-Path $base ('private-intake-backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $temp | Out-Null
$written=@()
try{
 foreach($name in $files.Keys){
  $out=Join-Path $temp $name
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'+$name) -OutFile $out -TimeoutSec 40
  if((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant() -ne $files[$name]){throw ('SHA incorrecto: '+$name)}
  & $node --check $out
  if($LASTEXITCODE -ne 0){throw ('Sintaxis incorrecta: '+$name)}
 }
 Assert-Idle
 New-Item -ItemType Directory -Path $backup | Out-Null
 foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $base $name) -Destination (Join-Path $backup $name)}
 foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $temp $name) -Destination (Join-Path $base $name) -Force;$written+=$name}
 Write-Host 'Recogida privada actualizada para Tendencias y Titulares. Tarea oculta conservada.' -ForegroundColor Green
 Write-Host 'Los proximos encargos esperan recepcion privada antes de reutilizar su conversacion. Solo Aprobar en APP publica.'
 Write-Host ('Backup: '+$backup)
}catch{
 foreach($name in $written){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $base $name) -Force}
 throw
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
