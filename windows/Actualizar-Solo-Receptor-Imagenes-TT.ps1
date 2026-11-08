#requires -Version 5.1
# Safe one-component repair. The two generators load their WebImages.cjs
# modules, NOT TTImageApprovalReceiver.cjs. Do not wait for/stop generators.
# Only the NEXT receiver invocation loads the updated receiver script.
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$file='TTImageApprovalReceiver.cjs'
$live=Join-Path $base $file
$pin='f90c0a2764c55c0230bdb746428d10d6076a2d6e'
$expected='d311fb31975a96c71aab9b14239089d5f55b75d4f2fe23ae55d1525023ac5ca1'
$accepted=@(
 '5e4105171a9f27a42f619ce3fba7d912c2e5abf50a5fb7828e571491b2d9805a',
 '1dfdca82a23813c1e72a5468dc7e05a14c16b2373f4bd0a94aea27676ebc54e4',
 '340c1d28024d532310c51648794331a541bf93299e4db7a2365d6095b94129f1', # receptor físicamente verificado por el editor 07/11/2026
 $expected
)
# Exact SHA-256 of verified historical bridge revisions, normalized to CRLF.
# All enumerated revisions retain the manual_approval_required pause and the
# readEditorialState/readImageJob/discoverConversation/rasterProbe exports used
# by this receiver. These dependencies are read-only, never replaced here.
$dependencies=@{
 'TTendenciasWebImages.cjs'=@(
  '2b20c5ea4075a75b99014b47a60c68b59f3c7499c8fadcd54749d9d640dcf862', # 2026-11-02 manual approval pause
  '190384d1ef7370495b8b33eba6f5b1d132f9e5945c6fff5e2432a3fb72860cab', # 2026-11-03 message reader
  'd8b6e66006d63d478e641ffe8fe1040fad3bec538791147bf40499826a7443bb', # 2026-11-03 user bubbles
  '3032a4813547cd1cde963a67c28700f0befb5054f5bf4e8e371a42634f9bd8b8', # 2026-11-06 private inbox
  '4f2f00db3aa3794e1c293201fc9f32e6f6dcd4cacc27c7742da0db93d9292e3f' # receiver companion release
 )
 'TTiTTularesWebImages.cjs'=@(
  'da12b28af6e2f667515b851bb44f609148078a2c72d3f9ed9ecf077f19854b80', # 2026-11-02 manual approval pause
  '2bf584a4f266d1ed8c4781b81c27a5e47379c2c94e6802ad51902a99c48c287e', # 2026-11-03 message reader
  '6f1e5e9b390ab04ce068683b2d61535bda441550f419e4c04dc8896d1dabfb19', # 2026-11-03 user bubbles
  'b163d1a60ceefe75205b81a9e10c002805e3c8bfc52e175068fb080bae22c3ea', # 2026-11-06 private inbox
  '7b7bc8d6e4e9a84e47714528df3cbe19e1feae7b11286712dd76d587396f707b' # receiver companion release
 )
}
function Get-CanonicalSourceHash([string]$path) {
 $decoder=[System.Text.UTF8Encoding]::new($false,$true)
 $source=[IO.File]::ReadAllText($path,$decoder)
 if($source.Replace("`r`n",'').Contains("`r")){throw ('Linea no valida: '+$path)}
 $canonical=$source.Replace("`r`n","`n").Replace("`n","`r`n")
 $bytes=[Text.Encoding]::UTF8.GetBytes($canonical)
 $sha=[Security.Cryptography.SHA256]::Create()
 try {return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}
 finally {$sha.Dispose()}
}
if(-not(Test-Path -LiteralPath $live -PathType Leaf)){throw 'RECEIVER_NOT_FOUND: sin cambios'}
$before=Get-CanonicalSourceHash $live
if($accepted -notcontains $before){
 throw ('RECEIVER_UNKNOWN_SHA: '+$before+'. No se sobrescribe.')
}
foreach($entry in $dependencies.GetEnumerator()){
 $dependency=Join-Path $base $entry.Key
 if(-not(Test-Path -LiteralPath $dependency -PathType Leaf)){
  throw ('RECEIVER_DEPENDENCY_MISSING: '+$entry.Key)
 }
 $dependencyHash=Get-CanonicalSourceHash $dependency
 if($entry.Value -notcontains $dependencyHash){
  throw ('RECEIVER_DEPENDENCY_UNKNOWN: '+$entry.Key+' canonicalSHA256='+$dependencyHash+'. Sin cambios.')
 }
 $source=[IO.File]::ReadAllText($dependency)
 if(-not($source.Contains("return {status:'waiting',reason:'manual_approval_required'}"))){
  throw ('RECEIVER_APPROVAL_PAUSE_MISSING: '+$entry.Key)
 }
 foreach($export in @('readEditorialState','readImageJob','discoverConversation','rasterProbe','chatURL')){
  if(-not $source.Contains($export)){throw ('RECEIVER_DEPENDENCY_EXPORT_MISSING: '+$entry.Key+' '+$export)}
 }
}
$task=Get-ScheduledTask -TaskName 'TT Actualidad - Imagenes pendientes APP' -ErrorAction Stop
if(-not @($task.Actions | Where-Object {[IO.Path]::GetFileName($_.Execute) -ieq 'wscript.exe'}).Count){
 throw 'RECEIVER_HIDDEN_TASK_REQUIRED'
}
if($before -eq $expected){
 Write-Host 'RECEIVER_ALREADY_SAFE: nueva version presente; no se ha modificado nada.'
 return
}
$node=(Get-Command node.exe -ErrorAction Stop).Source
$download=Join-Path $env:TEMP ('TTReceiverOnly-'+[guid]::NewGuid().ToString('N')+'.cjs')
$stage=Join-Path $base ('.TTImageApprovalReceiver.stage-'+[guid]::NewGuid().ToString('N')+'.cjs')
$backupDir=Join-Path $base ('receiver-only-backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
$replaced=$false
try {
 Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'+$file) -OutFile $download -TimeoutSec 60
 if((Get-CanonicalSourceHash $download) -ne $expected){throw 'RECEIVER_DOWNLOAD_SHA_INVALID'}
 & $node --check $download
 if($LASTEXITCODE -ne 0){throw 'RECEIVER_JS_SYNTAX_INVALID'}
 $code=[IO.File]::ReadAllText($download)
 foreach($marker in @('MAX_NEW_RELAY_TABS_PER_CYCLE=1','RELAY_CLEANUP_UNCONFIRMED','Target.closeTarget')){
  if(-not $code.Contains($marker)){throw ('RECEIVER_GUARD_MISSING: '+$marker)}
 }
 Copy-Item -LiteralPath $download -Destination $stage -Force
 if((Get-CanonicalSourceHash $stage) -ne $expected){throw 'RECEIVER_STAGE_SHA_INVALID'}
 if((Get-CanonicalSourceHash $live) -ne $before){throw 'RECEIVER_CHANGED_DURING_STAGE'}
 New-Item -ItemType Directory -Path $backupDir -ErrorAction Stop|Out-Null
 [IO.File]::Replace($stage,$live,(Join-Path $backupDir $file),$true)
 $replaced=$true
 if((Get-CanonicalSourceHash $live) -ne $expected){throw 'RECEIVER_REPLACEMENT_SHA_INVALID'}
 Write-Host 'RECEIVER_ONLY_SAFE_OK: receptor actualizado con limite de una pestaña temporal por ciclo.'
 Write-Host 'Los generadores siguen funcionando y no se han cambiado sus archivos.'
 Write-Host 'No se ha iniciado Chrome ni activado ninguna tarea programada.'
 Write-Host ('Copia de seguridad: '+$backupDir)
} catch {
 if($replaced){
  $old=Join-Path $backupDir $file
  if(Test-Path -LiteralPath $old){
   $restore=Join-Path $base ('.TTImageApprovalReceiver.restore-'+[guid]::NewGuid().ToString('N')+'.cjs')
   try {
    Copy-Item -LiteralPath $old -Destination $restore -Force
    [IO.File]::Replace($restore,$live,$null,$true)
   }finally{Remove-Item -LiteralPath $restore -Force -ErrorAction SilentlyContinue}
  }
 }
 throw
} finally {
 Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
}
