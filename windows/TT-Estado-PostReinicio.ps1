# TT estado post-reinicio, solo lectura. No reinicia ni publica.
$ErrorActionPreference='Continue'
function Section([string]$s) {Write-Host '';Write-Host ('=== '+$s+' ===') -ForegroundColor Cyan}
function Tail([string]$p) {
  if(-not (Test-Path -LiteralPath $p)){Write-Host ('NO ENCONTRADO '+$p);return}
  $m=Get-Item -LiteralPath $p
  Write-Host ('LOG '+$p+' | '+$m.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
  Get-Content -LiteralPath $p -Tail 4 -ErrorAction SilentlyContinue | ForEach-Object {Write-Host $_}
}
$base='C:\TTiTTulares'
Section 'REINICIO WINDOWS'
Write-Host ('Ahora: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try{Write-Host ('Ultimo arranque: '+(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime)}catch{}
Section 'TAREAS PROGRAMADAS'
$names=@('TT Chrome Auto','TTiTTulares Local Ready','TTendencias Local Ready','TTiTTulares Local','TTendencias Local','SeLoRecordamos-Telegram','SeLoRecordamos-Search','SeLoRecordamos-Published','SeLoRecordamos-Watchdog')
$rows=@(foreach($n in $names){
 try{$t=Get-ScheduledTask -TaskName $n -ErrorAction Stop;$i=Get-ScheduledTaskInfo -TaskName $n -ErrorAction Stop
 [pscustomobject]@{Tarea=$n;Estado=[string]$t.State;Ultima=$i.LastRunTime;Resultado=$i.LastTaskResult;Proxima=$i.NextRunTime}}
 catch{[pscustomobject]@{Tarea=$n;Estado='NO ENCONTRADA';Ultima='-';Resultado='-';Proxima='-'}}
})
$rows | Format-Table -AutoSize | Out-String -Width 210 | Write-Host
Section 'PROCESOS DE AUTOMATIZACION'
try{$all=@(Get-CimInstance Win32_Process -ErrorAction Stop)}catch{$all=@();Write-Host $_.Exception.Message}
$roles=@(
 @('TT Watchdog','TT-LocalWatchdog[.]ps1'),@('TTiTTulares Listener','TTiTTularesDedicatedListener[.]ps1'),
 @('TTendencias Listener','TTendenciasDedicatedListener[.]ps1'),@('TT AutoUpdater','TT-AutoUpdater[.]ps1'),
 @('SLR Telegram','run-telegram-listener[.]ps1|telegram_local[.]js'),
 @('SLR Search','selorecordamos[\\/](run-search[.]ps1|search_x[.]js)'),
 @('SLR Published','selorecordamos[\\/](run-published-import[.]ps1|import_published[.]js)'),
 @('SLR Watchdog','selorecordamos[\\/]watchdog[.]ps1'),
 @('TT Imagen','(TTiTTulares|TTendencias)ImageBridge[.]js'))
$procrows=@(foreach($r in $roles){
 $found=@($all | Where-Object {$_.Name -in @('powershell.exe','pwsh.exe','node.exe','wscript.exe') -and [string]$_.CommandLine -match $r[1]})
 if($found.Count -eq 0){[pscustomobject]@{Servicio=$r[0];PID='-';Inicio='-';Estado='NO DETECTADO'}}
 else{foreach($p in $found){[pscustomobject]@{Servicio=$r[0];PID=$p.ProcessId;Inicio=$p.CreationDate;Estado='ACTIVO'}}}
})
$procrows | Format-Table -AutoSize | Out-String -Width 170 | Write-Host
Write-Host 'Nota: bridges e importadores solo aparecen durante su trabajo.'
Section 'CHROME RAM POR NAVEGADOR'
$c=@($all | Where-Object {$_.Name -eq 'chrome.exe'})
$index=@{};foreach($p in $c){$index[[int]$p.ProcessId]=$p}
$groups=@{}
foreach($p in $c){
 $root=$p;$seen=@{}
 for($j=0;$j -lt 100;$j++){
  $parent=[int]$root.ParentProcessId
  if($seen.ContainsKey($parent) -or -not $index.ContainsKey($parent)){break}
  if([datetime]$index[$parent].CreationDate -gt [datetime]$root.CreationDate){break}
  $seen[$parent]=$true;$root=$index[$parent]
 }
 $id=[int]$root.ProcessId
 if(-not $groups.ContainsKey($id)){$groups[$id]=@()}
 $groups[$id]+=$p
}
$cr=@(foreach($id in $groups.Keys){
 $g=@($groups[$id]);$root=$index[[int]$id]
 $label=if([string]$root.CommandLine -match 'remote-debugging-port(?:=|\s+)9223'){'TT Chrome 9223'}else{'Chrome personal / otros'}
 [pscustomobject]@{Grupo=$label;PID=$id;Procesos=$g.Count;Renderizadores=@($g | Where-Object {[string]$_.CommandLine -match '--type=renderer'}).Count;RAM_GB=[math]::Round(($g | Measure-Object WorkingSetSize -Sum).Sum/1GB,2)}
})
$cr | Sort-Object RAM_GB -Descending | Format-Table -AutoSize | Out-String -Width 170 | Write-Host
Section 'PUERTO 9223'
try{@(Get-NetTCPConnection -LocalPort 9223 -State Listen -ErrorAction Stop) | ForEach-Object {Write-Host ('Escucha '+$_.LocalAddress+':9223 PID='+$_.OwningProcess)}}catch{Write-Host 'No hay listener visible'}
$targets=$null
foreach($u in @('http://127.0.0.1:9223/json/list','http://[::1]:9223/json/list')){
 try{$targets=@(Invoke-RestMethod -Uri $u -TimeoutSec 4 -ErrorAction Stop);Write-Host ('CDP OK: '+$u);break}catch{}
}
if($null -eq $targets){Write-Host 'CDP sin respuesta'}
else{
 $pages=@($targets | Where-Object {$_.type -eq 'page'})
 $h=@($pages | Where-Object {$_.url -eq 'https://chatgpt.com/'})
 $cv=@($pages | Where-Object {[string]$_.url -match '^https://chatgpt[.]com/c/'})
 Write-Host ('Paginas='+$pages.Count+' Home='+$h.Count+' Conversaciones='+$cv.Count)
 foreach($n in @('ttittulares-image-tab.json','ttendencias-image-tab.json')){
  try{$pin=Get-Content (Join-Path $base $n) -Raw -ErrorAction Stop | ConvertFrom-Json;$ok=@($pages | Where-Object {$_.id -eq [string]$pin.target_id}).Count -gt 0
   Write-Host ($n+': '+$(if($ok){'ACTIVA'}else{'REFERENCIA OBSOLETA'}))}
  catch{Write-Host ($n+': no encontrada')}
 }
}
Section 'LOGS TT'
foreach($n in @('tt-local-watchdog.log','ttittulares-mobile-trigger.log','ttendencias-mobile-trigger.log','tt-auto-updater.log')){Tail (Join-Path $base $n)}
Section 'LOGS SELORECORDAMOS'
$slr=Join-Path $env:USERPROFILE 'europapress-rss\selorecordamos'
if(-not (Test-Path -LiteralPath $slr)){
 try{$t=Get-ScheduledTask -TaskName 'SeLoRecordamos-Telegram' -ErrorAction Stop
 foreach($a in @($t.Actions)){if([string]$a.Arguments -match '([A-Za-z]:\\[^"\r\n]*\\selorecordamos)\\run-telegram-hidden[.]vbs'){$slr=$Matches[1];break}}}catch{}
}
Write-Host ('Carpeta SLR: '+$slr)
foreach($n in @('telegram-listener.log','search-task.log','published-import-task.log','watchdog.log')){Tail (Join-Path (Join-Path $slr 'runtime') $n)}
Section 'FIN: NO SE HA MODIFICADO NADA'
