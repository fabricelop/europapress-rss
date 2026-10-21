#requires -Version 5.1
# TTImages: read-only audit of Chrome debugging targets after failed recovery.
# Does NOT open, close, activate, reload any tab, start tasks or change files.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$base='http://127.0.0.1:9234'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
Write-Host ('TTIMAGES_TARGETS '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try{
 $version=Invoke-RestMethod -Uri ($base+'/json/version') -TimeoutSec 6
 Write-Host ('BROWSER '+[string]$version.Browser)
 $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 6)
 Write-Host ('NUM_TARGETS '+$list.Count)
 $rank=0
 foreach($t in $list){
   $rank++
   $id=[string]$t.id
   $u=[string]$t.url
   $ws=[string]$t.webSocketDebuggerUrl
   $category=if($u -match '^https://chatgpt\.com/images(?:[/?#]|$)'){'GALERIA'}
     elseif($u -match '^about:'){'ABOUT'}
     elseif($u -match '^https://chatgpt\.com(?:[/?#]|$)'){'CHATGPT_OTRA'}
     elseif($u -match '^chrome:'){'CHROME_INTERNA'}else{'OTRA'}
   $idType=if($null -eq $t.id){'NULL'}else{$t.id.GetType().Name}
   $wsMatches=if($id.Length -gt 0){$ws.EndsWith('/'+$id,[StringComparison]::Ordinal)}else{$false}
   Write-Host ('TAB '+$rank+' type='+[string]$t.type+' category='+$category+
     ' id_type='+$idType+' id_length='+$id.Length+
     ' ws_length='+$ws.Length+' ws_suffix_matches_id='+$wsMatches)
 }
}catch{
 Write-Host ('CHROME9234_ERROR '+$_.Exception.Message)
}
Write-Host '--- CAPTURA ---'
foreach($name in @('informe-captura-v2.json','relay-auto-v2.json')){
 $p=Join-Path $root $name
 if(-not(Test-Path -LiteralPath $p)){continue}
 Write-Host ('REPORT '+$name+' updated='+((Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
 try{
  $d=Get-Content -LiteralPath $p -Raw -Encoding UTF8 |ConvertFrom-Json
  foreach($field in @('error','status','ok','capturadas','descargadas','enviadas','last_capture_at','last_download_at','last_sent_at')){
    if($d.PSObject.Properties[$field]){
      $v=[string]$d.$field
      if($v.Length -gt 150){$v=$v.Substring(0,150)}
      Write-Host ('  '+$field+'='+$v)
    }
  }
 }catch{Write-Host ('  REPORT_ERROR '+$_.Exception.Message)}
}
foreach($name in @('relay-captura-v2.log','Telegram\telegram-v2.log')){
 $p=Join-Path $root $name
 if(Test-Path -LiteralPath $p){
  Write-Host ('LOG '+$name)
  Get-Content -LiteralPath $p -Tail 5 -Encoding UTF8 |
   ForEach-Object{
    $line=[string]$_
    $line=$line -replace '(?i)bot[0-9]{6,14}:[A-Za-z0-9_-]{18,}','bot[OCULTO]'
    if($line.Length -gt 240){$line=$line.Substring(0,240)}
    Write-Host ('  '+$line)
   }
 }
}
Write-Host 'SOLO LECTURA: ninguna pestana, tarea, archivo, imagen o mensaje modificado.'
