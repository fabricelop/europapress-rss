#requires -Version 5.1
<#
 Instalador manual seguro del receptor de Noticias y su helper GitHub.
 Sin -Apply: SOLO LECTURA. Con -Apply: descarga/valida los dos modulos,
 copia versiones previas y sustituye archivos. Nunca toca ImageGen,
 Chrome, listeners, Telegram, X, Instagram ni ningun Worker.
 Para version de pruebas usar -Ref fix/ttimages-original-association-v1.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [ValidatePattern('^[A-Za-z0-9._/-]{3,120}$')]
  [string]$Ref='main'
)
$ErrorActionPreference='Stop'
$root='C:\TTiTTulares'
$files=@(
  @{ Name='TTiTTularesGithubOutbox.cjs'; Checks=@('function buildReceipt(task,row,raster)','async function pushReceipt(task,row,raster') },
  @{ Name='TTiTTularesWebImages.cjs'; Checks=@('function rasterProbe(command)','function cacheRaster(task,raster','TTiTTularesGithubOutbox.cjs','module.exports=') }
)
function Sha256Bytes([byte[]]$bytes){
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
  finally{$sha.Dispose()}
}
function Report([string]$status,[string]$detail=''){
  Write-Host ('TTIMAGE_NEWS_STAGE '+$status+' '+$detail)
}
Report 'START' $(if($Apply){'APPLY_TWO_MODULES_ONLY'}else{'READ_ONLY'})
Report 'ROOT' $(if(Test-Path -LiteralPath $root){'PRESENT'}else{'MISSING'})
foreach($entry in $files){
  $dest=Join-Path $root ([string]$entry.Name)
  Report ([string]$entry.Name) $(if(Test-Path -LiteralPath $dest){'INSTALLED'}else{'ABSENT'})
}
$node=Get-Command node.exe -ErrorAction SilentlyContinue
Report 'NODE' $(if($node){'PRESENT'}else{'ABSENT'})
if(-not $Apply){
  Report 'END' 'NO_CHANGES (use -Apply to stage modules)'
  return
}
if(-not(Test-Path -LiteralPath $root)){throw 'C:\TTiTTulares no existe: instalacion cancelada'}
if(-not $node){throw 'Node.js no encontrado: instalacion cancelada'}
$staged=@()
$installed=@()
try{
  # Descargar y validar AMBOS antes de sustituir ningun archivo.
  foreach($entry in $files){
    $name=[string]$entry.Name
    $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$Ref+'/windows/'+$name
    $temp=Join-Path $env:TEMP ('ttimages-news-'+[guid]::NewGuid().ToString('N')+'.cjs')
    Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $temp -TimeoutSec 25 -Headers @{'Cache-Control'='no-cache'} -ErrorAction Stop|Out-Null
    $bytes=[IO.File]::ReadAllBytes($temp)
    if($bytes.Length -lt 1500){throw ('Descarga incompleta: '+$name)}
    $text=[Text.Encoding]::UTF8.GetString($bytes)
    foreach($must in $entry.Checks){
      if(-not $text.Contains([string]$must)){throw ('Contrato incompleto: '+$name+' '+$must)}
    }
    & $node.Source --check $temp|Out-Null
    if($LASTEXITCODE -ne 0){throw ('JS invalido: '+$name)}
    $dest=Join-Path $root $name
    $staged+=@{Temp=$temp;Dest=$dest;Name=$name;Hash=(Sha256Bytes $bytes)}
  }
  foreach($item in $staged){
    $oldHash=''
    if(Test-Path -LiteralPath $item.Dest){$oldHash=Sha256Bytes ([IO.File]::ReadAllBytes($item.Dest))}
    if($oldHash -eq $item.Hash){Report 'UNCHANGED' $item.Name;continue}
    if(Test-Path -LiteralPath $item.Dest){
      Copy-Item -LiteralPath $item.Dest -Destination ($item.Dest+'.safe.bak') -Force -ErrorAction Stop
    }
    $stage=$item.Dest+'.stage-new.cjs'
    if(Test-Path -LiteralPath $stage){throw ('Stage anterior pendiente: '+$item.Name)}
    [IO.File]::WriteAllBytes($stage,[IO.File]::ReadAllBytes($item.Temp))
    Move-Item -LiteralPath $stage -Destination $item.Dest -Force -ErrorAction Stop
    $installed+=$item
    Report 'INSTALLED' ($item.Name+' sha256='+$item.Hash)
  }
  Report 'SERVICE' 'UNCHANGED: no processes, prompts, images or Worker modified'
} catch {
  # Si la segunda instalacion falla, restaurar la primera cuando existe backup.
  foreach($item in $installed){
    $backup=$item.Dest+'.safe.bak'
    if(Test-Path -LiteralPath $backup){
      Copy-Item -LiteralPath $backup -Destination $item.Dest -Force -ErrorAction SilentlyContinue
    }else{
      Remove-Item -LiteralPath $item.Dest -Force -ErrorAction SilentlyContinue
    }
  }
  throw
} finally {
  foreach($item in $staged){
    Remove-Item -LiteralPath $item.Temp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($item.Dest+'.stage-new.cjs') -Force -ErrorAction SilentlyContinue
  }
  Report 'END' 'MODULES_ONLY'
}
