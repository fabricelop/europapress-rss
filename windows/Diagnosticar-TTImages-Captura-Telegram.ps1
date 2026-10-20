#requires -Version 5.1
# READ ONLY: TTImages v3 capture, Chrome 9234 viewer, scheduled tasks and Telegram logs.
# Does not start/stop Chrome, alter tasks, change files, or send messages.
$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
function Out([string]$s){Write-Host ('TTIMAGES_DIAG '+$s)}
function Safe([string]$s){
  $v=$s -replace '(?i)bot[0-9]{6,14}:[A-Za-z0-9_-]{18,}','bot[OCULTO]'
  $v=$v -replace '(?i)(authorization|api_key|api_token|bot_token|secret|password)\s*[:=]\s*["'']?[^\s,"'']+','$1=[OCULTO]'
  $v=$v -replace '(?i)https://api\.telegram\.org/bot[^/\s]+','https://api.telegram.org/bot[OCULTO]'
  if($v.Length -gt 320){$v=$v.Substring(0,320)}
  return $v
}
Out ('START '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Out ('ROOT_PRESENT '+(Test-Path -LiteralPath $root))
if(-not(Test-Path -LiteralPath $root)){Out 'STOP TTImageRelay no encontrado';return}
Out 'SECTION CHROME9234'
try{
  $version=Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/version' -TimeoutSec 6 -ErrorAction Stop
  Out ('BROWSER '+[string]$version.Browser)
  $raw=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 8 -ErrorAction Stop
  $parsed=ConvertFrom-Json -InputObject ([string]$raw.Content) -ErrorAction Stop
  [object[]]$tabs=@($parsed)
  if($tabs.Count -eq 1 -and $tabs[0] -is [array]){$tabs=@($tabs[0])}
  Out ('TARGETS_TOTAL '+$tabs.Count)
  $pages=@($tabs|Where-Object{[string]$_.type -eq 'page'})
  $gallery=@($pages|Where-Object{[string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
  Out ('PAGES '+$pages.Count+' GALLERY '+$gallery.Count)
  foreach($tab in $pages){
    $u=[string]$tab.url
    $cat=if($u -match '^https://chatgpt\.com/images(?:[/?#]|$)'){'GALLERY'}
      elseif($u -match '^https://chatgpt\.com/'){'OTHER_CHATGPT'}
      elseif($u -match '^about:|^chrome:'){'INTERNAL'}else{'OTHER'}
    $id=[string]$tab.id
    Out ('PAGE kind='+$cat+' id_prefix='+$id.Substring(0,[math]::Min(12,$id.Length))+' websocket='+[bool]([string]$tab.webSocketDebuggerUrl))
  }
}catch{Out ('CHROME_ERROR '+(Safe ([string]$_.Exception.Message)))}
Out 'SECTION TASKS'
foreach($name in @(
 'TT Image Relay - Telegram v2',
 'TT Image Relay - Botones v2',
 'TTImages - AutoRecovery Viewer',
 'TTImageRelay - Limpiar Originales 12h')){
 try{
   $t=Get-ScheduledTask -TaskName $name -ErrorAction Stop
   $i=$t|Get-ScheduledTaskInfo -ErrorAction Stop
   Out ('TASK '+$name+' state='+$t.State+' last='+$i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')+' result='+$i.LastTaskResult)
 }catch{Out ('TASK_MISSING_OR_UNREADABLE '+$name)}
}
Out 'SECTION ORIGINALS'
$dir=Join-Path $root 'Originales'
if(Test-Path -LiteralPath $dir){
  $images=@(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
    Where-Object{$_.Extension -in @('.png','.jpg','.jpeg','.webp')} |
    Sort-Object LastWriteTime -Descending)
  Out ('ORIGINALS total='+$images.Count+' last_1h='+@($images|Where-Object{$_.LastWriteTime -gt (Get-Date).AddHours(-1)}).Count)
  foreach($image in @($images|Select-Object -First 3)){
    Out ('IMAGE time='+$image.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' mb='+[math]::Round($image.Length/1MB,2))
  }
}else{Out 'ORIGINALS_DIR_MISSING'}
Out 'SECTION REPORTS'
foreach($rel in @(
 'informe-captura-v2.json',
 'App_v2\informe-captura-v2.json',
 'relay-auto-v2.json',
 'App_v2\relay-auto-v2.json',
 'auto-recovery-v1-state.json')){
 $f=Join-Path $root $rel
 if(-not(Test-Path -LiteralPath $f)){continue}
 Out ('REPORT '+$rel+' updated='+(Get-Item -LiteralPath $f).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
 try{
   $j=Get-Content -LiteralPath $f -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
   foreach($key in @('ok','status','error','motivo','reason','stop_reason','nuevas','guardados','descargadas','capturadas','enviadas','duplicados','visibles','pendientes','last_capture_at','last_download_at','last_sent_at','result')){
     $p=$j.PSObject.Properties[$key]
     if($p -and $null -ne $p.Value){
       $v=[string]$p.Value
       if($v.Length -gt 220){$v=$v.Substring(0,220)}
       Out ('REPORT_FIELD '+$key+'='+(Safe $v))
     }
   }
 }catch{Out ('REPORT_ERROR '+$rel+' '+(Safe ([string]$_.Exception.Message)))}
}
Out 'SECTION LOGS'
foreach($rel in @(
 'relay-captura-v2.log',
 'App_v2\relay-captura-v2.log',
 'ciclo-v2.log',
 'App_v2\ciclo-v2.log',
 'telegram-v2.log',
 'Telegram\telegram-v2.log',
 'App_v2\telegram-v2.log',
 'App_v2\Telegram\telegram-v2.log',
 'auto-recovery-v1.log',
 'AutoRecovery-v1\auto-recovery-v1.log')){
 $f=Join-Path $root $rel
 if(-not(Test-Path -LiteralPath $f)){continue}
 Out ('LOG '+$rel+' updated='+(Get-Item -LiteralPath $f).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
 try{
   Get-Content -LiteralPath $f -Tail 12 -Encoding UTF8 -ErrorAction Stop|
     ForEach-Object{Out ('LINE '+(Safe ([string]$_)))}
 }catch{Out ('LOG_ERROR '+$rel)}
}
Out 'FINISHED READ_ONLY no browser/process/task/file modified'
