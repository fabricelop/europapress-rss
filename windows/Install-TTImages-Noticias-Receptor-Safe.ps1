#requires -Version 5.1
<#
 Safe preparation of the TTiTTulares ORIGINAL image receiver.
 Default mode is READ_ONLY. -Apply downloads and validates ONE inert .cjs
 file; does NOT change the existing bridge/listener, restart processes,
 send an image/prompt or modify a Cloudflare Worker.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [ValidatePattern('^[A-Za-z0-9._/-]{3,120}$')]
  [string]$Ref='fix/ttimages-original-association-v1'
)
$ErrorActionPreference='Stop'
$root='C:\TTiTTulares'
$target=Join-Path $root 'TTiTTularesWebImages.cjs'
$sourcePath='windows/TTiTTularesWebImages.cjs'
$raw='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$Ref+'/'+$sourcePath
function Report([string]$status,[string]$detail=''){
  Write-Host ('TTIMAGE_NEWS_STAGE '+$status+' '+$detail)
}
Report 'START' $(if($Apply){'APPLY_RECEIVER_ONLY'}else{'READ_ONLY'})
Report 'ROOT' $(if(Test-Path -LiteralPath $root){'PRESENT'}else{'MISSING'})
Report 'CONSUMER' $(if(Test-Path -LiteralPath $target){'INSTALLED'}else{'ABSENT'})
$node=Get-Command node.exe -ErrorAction SilentlyContinue
Report 'NODE' $(if($node){'PRESENT'}else{'ABSENT'})
if(-not $Apply){
  Report 'END' 'NO_CHANGES (use -Apply to stage receiver)'
  return
}
if(-not(Test-Path -LiteralPath $root)){throw 'C:\TTiTTulares no existe: no crear instalación nueva'}
if(-not $node){throw 'Node.js no encontrado: no modificar ficheros'}
$temp=Join-Path $env:TEMP ('ttimages-news-stage-'+[guid]::NewGuid().ToString('N')+'.cjs')
$staged=$target+'.stage-new.cjs'
$backup=$target+'.safe.bak'
try {
  Invoke-WebRequest -Uri $raw -UseBasicParsing -OutFile $temp -TimeoutSec 25 -Headers @{'Cache-Control'='no-cache'} -ErrorAction Stop | Out-Null
  $bytes=[IO.File]::ReadAllBytes($temp)
  if($bytes.Length -lt 10000){throw 'Archivo remoto demasiado pequeño o incompleto'}
  $text=[Text.Encoding]::UTF8.GetString($bytes)
  foreach($must in @('function rasterProbe(command)','function headlineFingerprint(snapshot)','function cacheRaster(task,raster','web_image_upload','module.exports=')){
    if(-not $text.Contains($must)){throw ('Contrato de receptor incompleto: '+$must)}
  }
  & $node.Source --check $temp | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Error de sintaxis Node: no modificar receptor'}
  $remoteSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
  $localSha=''
  if(Test-Path -LiteralPath $target){
    $oldBytes=[IO.File]::ReadAllBytes($target)
    $localSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oldBytes)).ToLowerInvariant()
  }
  if($localSha -eq $remoteSha){
    Report 'UNCHANGED' ('sha256='+$remoteSha)
    return
  }
  if(Test-Path -LiteralPath $staged){throw 'Existe una instalación pendiente: revisión manual antes de continuar'}
  [IO.File]::WriteAllBytes($staged,$bytes)
  if(Test-Path -LiteralPath $target){
    Copy-Item -LiteralPath $target -Destination $backup -Force -ErrorAction Stop
    Report 'BACKUP' 'TTiTTularesWebImages.cjs.safe.bak'
  }
  Move-Item -LiteralPath $staged -Destination $target -Force -ErrorAction Stop
  Report 'INSTALLED' ('sha256='+$remoteSha)
  Report 'SERVICE' 'UNCHANGED: no processes, prompts, images or Worker modified'
}finally{
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  # An incomplete stage file may be removed; the existing target is never deleted.
  if(Test-Path -LiteralPath $staged){Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
  Report 'END' 'RECEIVER_ONLY'
}
