#requires -Version 5.1
# TT_EDITORIAL_GUARD_HOTFIX_V1
# Update only the existing Chrome 9223 editorial guard. No Chrome/Windows restart,
# no changes to image bridges, queues, social publishing or listeners.
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$target=Join-Path $base 'TT-Editorial-Guard.js'
$installerUrl='https://raw.githubusercontent.com/fabricelop/europapress-rss/51b6f70504cad0594a85f290e84d791edb38f09b/windows/Reparar-TT-Editorial-20261111.ps1'
if(-not(Test-Path -LiteralPath $target)){throw 'TT-Editorial-Guard.js no existe. Nada modificado.'}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$srcFile=Join-Path $env:TEMP ('tt-guard-installer-'+[guid]::NewGuid().ToString('N')+'.ps1')
$stage=$target+'.hotfix-'+[guid]::NewGuid().ToString('N')+'.new.js'
try {
 Invoke-WebRequest -UseBasicParsing -Uri $installerUrl -OutFile $srcFile -TimeoutSec 35 -ErrorAction Stop
 $text=[IO.File]::ReadAllText($srcFile,[Text.Encoding]::UTF8)
 $m=[regex]::Match($text,'(?ms)^\$engine=@''\r?\n(?<code>.*?)^''@\r?$')
 if(-not $m.Success){throw 'No se pudo extraer el motor de forma segura; sin cambios'}
 $code=[string]$m.Groups['code'].Value
 foreach($required in @('TT_EDITORIAL_GUARD_V1',
   'let raw=String(ed?.value??ed?.textContent??' ,
   '[role="dialog"][aria-modal="true"]',
   "main [aria-busy=""true""]",
   'TRANSMISSION_UNVERIFIED',
   'TRANSMISSION_STATE',
   'function confirmedUserState(s,marker)',
   'userMessages:us.slice(-8)',
   'AMBIGUOUS_PREVIOUS_SEND')) {
  if(-not $code.Contains($required)){throw ('Falta control del motor: '+$required)}
 }
 [IO.File]::WriteAllText($stage,$code,[Text.UTF8Encoding]::new($false))
 & $node --check $stage
 if($LASTEXITCODE -ne 0){throw 'Motor descargado: sintaxis inválida'}
 & $node $stage --selftest
 if($LASTEXITCODE -ne 0){throw 'Motor descargado: autoprueba inválida'}
 $old=[IO.File]::ReadAllText($target,[Text.Encoding]::UTF8)
 if(-not $old.Contains('TT_EDITORIAL_GUARD_V1')){throw 'Motor local desconocido: no sobrescribir'}
 $oldHash=(Get-FileHash $target -Algorithm SHA256).Hash
 $newHash=(Get-FileHash $stage -Algorithm SHA256).Hash
 Write-Host ('GUARD_CHECK old='+$oldHash+' new='+$newHash)
 if($oldHash -eq $newHash){Write-Host 'GUARD_ALREADY_CURRENT';return}
 if($CheckOnly){Write-Host 'CHECK_ONLY no changes';return}
 $live=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
  [string]$_.CommandLine -match '(?i)[\\/]TT-Editorial-Guard[.]js|[\\/]Ejecutar[.]js'
 })
 if($live.Count){throw ('Actualización pospuesta: '+$live.Count+' lanzador(es) en ejecución.')}
 $backup=$target+'.before-hotfix-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
 Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
 try {
  Move-Item -LiteralPath $stage -Destination $target -Force -ErrorAction Stop
  & $node --check $target
  if($LASTEXITCODE -ne 0){throw 'Sintaxis inválida tras instalar'}
 }catch{
  Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
  throw
 }
 Write-Host ('GUARD_UPDATED backup='+$backup)
 Write-Host 'No se han reiniciado procesos ni lanzado trabajos.'
}finally{
 Remove-Item -LiteralPath $srcFile,$stage -Force -ErrorAction SilentlyContinue
}
