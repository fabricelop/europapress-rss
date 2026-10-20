#requires -Version 5.1
# TTImages relay v2 - DIAGNOSTICO SIN MODIFICACIONES
# No inicia tareas, no toca Chrome, no reinicia baseline ni reenvia mensajes.
$ErrorActionPreference='Continue'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
Write-Host ('TTIMAGES DIAGNOSTICO '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
Write-Host ('ROOT '+$root+' existe='+(Test-Path -LiteralPath $root))
if(-not (Test-Path -LiteralPath $root)){Write-Host 'ERROR: no existe la instalacion TTImageRelay';return}
Write-Host '--- TAREAS PROGRAMADAS ---'
foreach($name in @('TT Image Relay - Telegram v2','TT Image Relay - Botones v2','TTImageRelay - Limpiar Originales 12h')){
 try{
  $task=Get-ScheduledTask -TaskName $name -ErrorAction Stop
  $info=$task|Get-ScheduledTaskInfo -ErrorAction Stop
  Write-Host ('TASK '+$name+' Estado='+$task.State+' Ultima='+$info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')+' Proxima='+$info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss')+' Resultado='+$info.LastTaskResult)
  foreach($act in $task.Actions){
   $exe=Split-Path ([string]$act.Execute) -Leaf
   $args=[string]$act.Arguments
   if($args.Length -gt 180){$args=$args.Substring(0,180)}
   Write-Host ('  Action='+$exe+' Args='+$args)
  }
 }catch{Write-Host ('TASK '+$name+' SIN ENCONTRAR: '+$_.Exception.Message)}
}
Write-Host '--- CHROME INDEPENDIENTE 9234 ---'
try{
 $resp=Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/version' -TimeoutSec 4
 Write-Host ('CDP9234 OK Browser='+[string]$resp.Browser+' WebSocket='+[bool]$resp.webSocketDebuggerUrl)
}catch{Write-Host ('CDP9234 ERROR '+$_.Exception.Message)}
try{
 $conns=@(Get-NetTCPConnection -LocalPort 9234 -State Listen -ErrorAction Stop)
 Write-Host ('PORT9234 LISTEN '+$conns.Count+' PIDs='+(@($conns|ForEach-Object{$_.OwningProcess}|Sort-Object -Unique)-join ','))
}catch{Write-Host 'PORT9234 no comprobable via Get-NetTCPConnection'}
Write-Host '--- ORIGINALS / CAPTURA ---'
$original=Join-Path $root 'Originales'
if(Test-Path -LiteralPath $original){
 $photos=@(Get-ChildItem -LiteralPath $original -File -ErrorAction SilentlyContinue |Where-Object {$_.Extension -in @('.png','.jpg','.jpeg','.webp')} |Sort-Object LastWriteTime -Descending|Select-Object -First 6)
 Write-Host ('Originales recientes encontrados: '+$photos.Count+' (hasta 6)')
 foreach($p in $photos){Write-Host ('FILE '+$p.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' '+$p.Length+' bytes '+$p.Name)}
}else{Write-Host 'Originales no encontrado'}
$reportPaths=@(
 (Join-Path $root 'informe-captura-v2.json'),
 (Join-Path $root 'App_v2\informe-captura-v2.json'),
 (Join-Path $root 'relay-auto-v2.json'),
 (Join-Path $root 'App_v2\relay-auto-v2.json')
)
foreach($path in ($reportPaths|Select-Object -Unique)){
 if(-not(Test-Path -LiteralPath $path)){continue}
 Write-Host ('REPORT '+$path+' actualizado='+((Get-Item -LiteralPath $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
 try{
  $obj=Get-Content -LiteralPath $path -Raw -Encoding UTF8 |ConvertFrom-Json
  foreach($key in @('ok','status','motivo','reason','nuevas','descargadas','capturadas','visibles','auth','chrome9234','challengeHint','loginHint','error','last_capture_at','last_download_at','last_sent_at','total_downloaded','total_sent')){
   $prop=$obj.PSObject.Properties[$key]
   if($null -ne $prop -and $null -ne $prop.Value -and $prop.Value -isnot [psobject] -and $prop.Value -isnot [array]){
    $val=[string]$prop.Value
    if($val.Length -gt 220){$val=$val.Substring(0,220)}
    Write-Host ('  '+$key+'='+$val)
   }
  }
 }catch{Write-Host ('  JSON ERROR '+$_.Exception.Message)}
}
Write-Host '--- LOGS ULTIMAS LINEAS (secretos ocultos) ---'
$relative=@('ciclo-v2.log','App_v2\ciclo-v2.log','relay-captura-v2.log','App_v2\relay-captura-v2.log','Telegram\telegram-v2.log','App_v2\Telegram\telegram-v2.log','telegram-v2.log','App_v2\telegram-v2.log')
$found=0
foreach($rel in $relative){
 $path=Join-Path $root $rel
 if(-not(Test-Path -LiteralPath $path)){continue}
 $found++
 Write-Host ('LOG '+$rel+' actualizado='+((Get-Item -LiteralPath $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
 try{
  Get-Content -LiteralPath $path -Tail 16 -Encoding UTF8 -ErrorAction Stop|ForEach-Object{
   $line=[string]$_
   $line=$line -replace '(?i)bot[0-9]{6,14}:[A-Za-z0-9_-]{18,}','bot[OCULTO]'
   $line=$line -replace '(?i)(authorization|api_key|api_token|bot_token|secret|password)\s*[:=]\s*["'']?[^\s,"'']+','$1=[OCULTO]'
   if($line.Length -gt 280){$line=$line.Substring(0,280)}
   Write-Host ('  '+$line)
  }
 }catch{Write-Host ('  LOG ERROR '+$_.Exception.Message)}
}
if(-not $found){Write-Host 'No se localizaron logs en las rutas v2 esperadas'}
Write-Host '--- RESULTADO ---'
$t=Get-ScheduledTask -TaskName 'TT Image Relay - Telegram v2' -ErrorAction SilentlyContinue
if($t -and $t.State -eq 'Disabled'){Write-Host 'POSIBLE CAUSA: tarea principal de captura/envio DESHABILITADA' -ForegroundColor Yellow}
Write-Host 'DIAGNOSTICO FINALIZADO: no se ha modificado ningun proceso, tarea, archivo ni mensaje.' -ForegroundColor Green
