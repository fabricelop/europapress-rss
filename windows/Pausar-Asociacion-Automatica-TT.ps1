#requires -Version 5.1
# Apply only the validated association pause; never start Telegram or restart Chrome/listeners.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$pin='49a43564b14344c9e385e7c5a59606432960904c'
$files=@{
 'TTendenciasWebImages.cjs'='595425bcb143776ae378a7d7a5e37bdabe0aa496631da39a9214adadb3580774'
 'TTiTTularesWebImages.cjs'='8ef3c4c1da5e4dfa0556c1f83e2db8e3f862a1ff028a168199dd562553e0467c'
 'TTendenciasImageBridge.js'='416069b713104821be1a76c53f3cf332f647ff83331aa293c993ef21f84a3283'
 'TTiTTularesImageBridge.js'='f5c2c3918184e10b4f9854191bed53bb4abf6fde76d69c1266067fdd27540851'
}
$allowed=@{
 'TTendenciasWebImages.cjs'=@('d16e7bda8d76b9b8b39d86d4123a6a2f72d7ce0e414de674e6f6ab7d6c677753','d20ed1b1c5568f49cb9791bb4879a8ca4711254d84a16e69bfa481a894e4ba29')
 'TTiTTularesWebImages.cjs'=@('4ac71521b9f529d9d66b8555a3ddb8a798dbe1f678827701a6c8f29dde445ded','13e04527eba31ebbdb0e1b93979ab3a91ee5af4068eee0e019fa75e7d0afa9a6')
 'TTendenciasImageBridge.js'=@('013f86210fb4f673378ca300ccc866f063e38acb3c2b0960a580222210b114a8','344f7a6dca4ac5e78fec1a07c032fd85a70ba1d7bd544893e7077440dc531923')
 'TTiTTularesImageBridge.js'=@('df615c30387aa720fb5880b11ea1306ab372492330956808e2c32951099ae53e','fbd23150bfcea704de79395a093083e42be88b6c3effe7c44b1751f1c1b42985')
}
function Get-NormalizedHash([string]$file) {
 $text=[IO.File]::ReadAllText($file).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
if(-not(Test-Path -LiteralPath $base)){throw 'No existe C:\TTiTTulares. Sin cambios.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
function Assert-GenerationIdle {
 $busy=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
  [string]$_.CommandLine -match '(?i)TT(endencias|iTTulares)ImageBridge\.js'
 })
 if($busy.Count){throw 'Hay generacion activa. No se modifica ni se interrumpe. Ejecuta de nuevo cuando termine.'}
}
Assert-GenerationIdle
foreach($name in $files.Keys){if(-not(Test-Path -LiteralPath (Join-Path $base $name))){throw ('Falta '+$name+'. Sin cambios.')}}
foreach($name in $files.Keys){
 if($allowed[$name] -notcontains (Get-NormalizedHash (Join-Path $base $name))){throw ('Version local no reconocida: '+$name+'. No se sustituye; necesita revision para conservar cambios.')}
}
$temp=Join-Path $env:TEMP ('TT-ImagePause-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$backup=Join-Path $base ('image-pause-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$written=@()
try {
 foreach($name in $files.Keys){
  $target=Join-Path $temp $name
  Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'+$name) -OutFile $target -TimeoutSec 40
  if((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant() -ne $files[$name]){throw ('Hash incorrecto: '+$name)}
  & $node --check $target
  if($LASTEXITCODE -ne 0){throw ('Sintaxis incorrecta: '+$name)}
 }
 Assert-GenerationIdle
 New-Item -ItemType Directory -Path $backup | Out-Null
 foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $base $name) -Destination (Join-Path $backup $name)}
 foreach($name in $files.Keys){
  $target=Join-Path $base $name
  Copy-Item -LiteralPath (Join-Path $temp $name) -Destination $target -Force
  $written+= $name
  if((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant() -ne $files[$name]){throw ('No coincide el archivo instalado: '+$name)}
 }
 # End only standalone old association consumers so future invocations load the paused version.
 # A concurrent image generator is never stopped or restarted.
 $publishers=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
  $line=[string]$_.CommandLine
  $line -match '(?i)C:\\TTiTTulares\\TT(endencias|iTTulares)WebImages\.cjs(?:["\s]|$)' -and
  $line -notmatch '(?i)ImageBridge\.js'
 })
 foreach($proc in $publishers){Stop-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue}
 Write-Host 'PAUSA INSTALADA: asociacion automatica APP/web bloqueada en los cuatro archivos.' -ForegroundColor Green
 Write-Host 'Generacion, Chrome, listeners, imagenes y catalogos conservados. Telegram no ejecutado.'
 Write-Host ('Backup: '+$backup)
 Write-Host 'Esto no instala todavia la bandeja de aprobacion ni revierte asociaciones anteriores.'
} catch {
 foreach($name in $written){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $base $name) -Force}
 throw
} finally {Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
