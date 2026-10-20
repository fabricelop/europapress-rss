#requires -Version 5.1
<#
TTImages v2.6.1 - bounded recovery of an orphaned ChatGPT Images viewer.
Touches ONLY a /images tab in the independent local Chrome CDP 9234,
when a fresh official capture report says viewer is already open.
Never accesses Chrome 9223, bot credentials, baselines, snapshots or originals.
#>
param([switch]$InspectOnly,[switch]$NoTaskStart)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
$report=Join-Path $root 'informe-captura-v2.json'
$taskName='TT Image Relay - Telegram v2'
function Say([string]$m){Write-Host ('TTIMAGES_VISOR '+$m)}
function ReadCDP([string]$ws,[string]$method,[object]$params){
  $c=[System.Net.WebSockets.ClientWebSocket]::new()
  $timeout=[System.Threading.CancellationTokenSource]::new(12000)
  try{
    $c.ConnectAsync([uri]$ws,$timeout.Token).GetAwaiter().GetResult()
    if($c.State -ne [System.Net.WebSockets.WebSocketState]::Open){throw 'WebSocket no conectado'}
    $msg=@{id=71;method=$method;params=$params}|ConvertTo-Json -Compress -Depth 5
    $bytes=[Text.Encoding]::UTF8.GetBytes($msg)
    $chunk=[System.ArraySegment[byte]]::new([byte[]]$bytes)
    $c.SendAsync($chunk,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,$timeout.Token).GetAwaiter().GetResult()
    # Chrome may emit Page events before the response. Ignore those,
    # and only accept the response for the exact command ID 71.
    while($true){
      $builder=[Text.StringBuilder]::new()
      do{
        $buffer=New-Object byte[] 32768
        $segment=[System.ArraySegment[byte]]::new([byte[]]$buffer)
        $part=$c.ReceiveAsync($segment,$timeout.Token).GetAwaiter().GetResult()
        if($part.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP WebSocket cerrado'}
        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer,0,$part.Count))
        if($builder.Length -gt 300000){throw 'Respuesta CDP demasiado larga'}
      }until($part.EndOfMessage)
      $data=$builder.ToString()|ConvertFrom-Json
      if($null -eq $data.id -or [int]$data.id -ne 71){continue}
      if($data.error){throw ('CDP Error '+$data.error.message)}
      return $data.result
    }
  }finally{
    try{$c.Dispose()}catch{}
    try{$timeout.Dispose()}catch{}
  }
}
# Fallback CDP HTTP endpoints, scoped to the single gallery Chrome 9234.
function RecoverGalleryByHttp([string]$oldId){
  if($oldId -notmatch '^[A-Fa-f0-9-]{8,64}
if(-not(Test-Path -LiteralPath $report)){throw 'No existe el informe de captura; no se puede asegurar el motivo del bloqueo'}
$reportFile=Get-Item -LiteralPath $report
$age=((Get-Date)-$reportFile.LastWriteTime).TotalMinutes
$doc=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
$reason=[string]$doc.error
Say ('INFORME '+$reportFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' antiguedad_min='+[int]$age+' error='+$reason)
if($age -lt 0 -or $age -gt 45 -or $reason -notmatch 'Visor ya abierto al iniciar'){
 Say 'SIN_ACCION informe no reciente o ya no indica visor bloqueado'
 return
}
$running=@(Get-CimInstance Win32_Process |Where-Object{
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
if($running.Count){
 Say ('SIN_ACCION captura en curso PID='+($running.ProcessId -join ','))
 return
}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -eq 'Running'){
 Say 'SIN_ACCION tarea de captura ejecutandose actualmente'
 return
}
if($task.State -ne 'Ready'){throw ('Tarea '+$taskName+' no lista: '+$task.State)}
$targets=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$gallery=@($targets|Where-Object{
  $_.type -eq 'page' -and
  ([string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)') -and
  [string]$_.webSocketDebuggerUrl -match '^ws://(?:127\.0\.0\.1|localhost):9234/'
})
Say ('CHROME9234 paginas='+$targets.Count+' galerias='+$gallery.Count)
if($gallery.Count -ne 1){
 Say 'SIN_ACCION no hay una unica galeria /images identificable; no se toca ningun navegador'
 return
}
if($InspectOnly){
 Say ('SOLO_DIAGNOSTICO visor probable en '+$gallery[0].url)
 return
}
# The viewer is a modal inside the /images SPA. Reload ONLY that dedicated
# gallery tab: it does not close the browser or modify image-delivery state.
$result=ReadCDP ([string]$gallery[0].webSocketDebuggerUrl) 'Page.reload' @{ignoreCache=$true}
Say 'RECUPERACION_EMITIDA Page.reload sobre unica pestaña ChatGPT Images / Chrome 9234'
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{ $_.id -eq $gallery[0].id -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
if(-not $still.Count){
 Say 'AVISO galeria aun no confirmada tras recarga; no se lanza ninguna tarea adicional'
 return
}
Say 'GALERIA9234 PESTANA DISPONIBLE; el visor deberia estar cerrado'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
){throw 'ID de galeria no reconocido'}
  $base='http://127.0.0.1:9234'
  $newId=''
  try{
    $created=Invoke-RestMethod -Method Put -Uri ($base+'/json/new?'+[Uri]::EscapeDataString('https://chatgpt.com/images')) -TimeoutSec 10 -ErrorAction Stop
    $newId=[string]$created.id
    if($newId -notmatch '^[A-Fa-f0-9-]{8,64}
if(-not(Test-Path -LiteralPath $report)){throw 'No existe el informe de captura; no se puede asegurar el motivo del bloqueo'}
$reportFile=Get-Item -LiteralPath $report
$age=((Get-Date)-$reportFile.LastWriteTime).TotalMinutes
$doc=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
$reason=[string]$doc.error
Say ('INFORME '+$reportFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' antiguedad_min='+[int]$age+' error='+$reason)
if($age -lt 0 -or $age -gt 45 -or $reason -notmatch 'Visor ya abierto al iniciar'){
 Say 'SIN_ACCION informe no reciente o ya no indica visor bloqueado'
 return
}
$running=@(Get-CimInstance Win32_Process |Where-Object{
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
if($running.Count){
 Say ('SIN_ACCION captura en curso PID='+($running.ProcessId -join ','))
 return
}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -eq 'Running'){
 Say 'SIN_ACCION tarea de captura ejecutandose actualmente'
 return
}
if($task.State -ne 'Ready'){throw ('Tarea '+$taskName+' no lista: '+$task.State)}
$targets=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$gallery=@($targets|Where-Object{
  $_.type -eq 'page' -and
  ([string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)') -and
  [string]$_.webSocketDebuggerUrl -match '^ws://(?:127\.0\.0\.1|localhost):9234/'
})
Say ('CHROME9234 paginas='+$targets.Count+' galerias='+$gallery.Count)
if($gallery.Count -ne 1){
 Say 'SIN_ACCION no hay una unica galeria /images identificable; no se toca ningun navegador'
 return
}
if($InspectOnly){
 Say ('SOLO_DIAGNOSTICO visor probable en '+$gallery[0].url)
 return
}
# The viewer is a modal inside the /images SPA. Reload ONLY that dedicated
# gallery tab: it does not close the browser or modify image-delivery state.
$result=ReadCDP ([string]$gallery[0].webSocketDebuggerUrl) 'Page.reload' @{ignoreCache=$true}
Say 'RECUPERACION_EMITIDA Page.reload sobre unica pestaña ChatGPT Images / Chrome 9234'
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{ $_.id -eq $gallery[0].id -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
if(-not $still.Count){
 Say 'AVISO galeria aun no confirmada tras recarga; no se lanza ninguna tarea adicional'
 return
}
Say 'GALERIA9234 PESTANA DISPONIBLE; el visor deberia estar cerrado'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
 -or $newId -eq $oldId){throw 'Nueva galeria sin ID valido'}
    $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5)
    $old=@($list|Where-Object{$_.id -eq $oldId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
    $fresh=@($list|Where-Object{$_.id -eq $newId -and $_.type -eq 'page'})
    if($old.Count -ne 1 -or $fresh.Count -ne 1 -or
        [string]$fresh[0].url -notmatch '^https://chatgpt\.com/images(?:[/?#]|$)'){
      throw 'Galeria nueva o anterior no confirmada; no se cierra la original'
    }
    [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+$oldId) -TimeoutSec 8 -ErrorAction Stop)
    $closed=$false
    for($attempt=0;$attempt -lt 5;$attempt++){
      Start-Sleep -Milliseconds 600
      $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5)
      $stillOld=@($list|Where-Object{$_.id -eq $oldId})
      $stillNew=@($list|Where-Object{$_.id -eq $newId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
      if($stillOld.Count -eq 0 -and $stillNew.Count -eq 1){$closed=$true;break}
    }
    if(-not $closed){throw 'No confirmado el cierre de galeria anterior; no se inicia captura'}
    Say 'RECUPERACION_HTTP_OK nueva galeria verificada; visor anterior cerrado'
    return $newId
  }catch{
    if($newId -match '^[A-Fa-f0-9-]{8,64}
if(-not(Test-Path -LiteralPath $report)){throw 'No existe el informe de captura; no se puede asegurar el motivo del bloqueo'}
$reportFile=Get-Item -LiteralPath $report
$age=((Get-Date)-$reportFile.LastWriteTime).TotalMinutes
$doc=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
$reason=[string]$doc.error
Say ('INFORME '+$reportFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' antiguedad_min='+[int]$age+' error='+$reason)
if($age -lt 0 -or $age -gt 45 -or $reason -notmatch 'Visor ya abierto al iniciar'){
 Say 'SIN_ACCION informe no reciente o ya no indica visor bloqueado'
 return
}
$running=@(Get-CimInstance Win32_Process |Where-Object{
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
if($running.Count){
 Say ('SIN_ACCION captura en curso PID='+($running.ProcessId -join ','))
 return
}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -eq 'Running'){
 Say 'SIN_ACCION tarea de captura ejecutandose actualmente'
 return
}
if($task.State -ne 'Ready'){throw ('Tarea '+$taskName+' no lista: '+$task.State)}
$targets=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$gallery=@($targets|Where-Object{
  $_.type -eq 'page' -and
  ([string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)') -and
  [string]$_.webSocketDebuggerUrl -match '^ws://(?:127\.0\.0\.1|localhost):9234/'
})
Say ('CHROME9234 paginas='+$targets.Count+' galerias='+$gallery.Count)
if($gallery.Count -ne 1){
 Say 'SIN_ACCION no hay una unica galeria /images identificable; no se toca ningun navegador'
 return
}
if($InspectOnly){
 Say ('SOLO_DIAGNOSTICO visor probable en '+$gallery[0].url)
 return
}
# The viewer is a modal inside the /images SPA. Reload ONLY that dedicated
# gallery tab: it does not close the browser or modify image-delivery state.
$result=ReadCDP ([string]$gallery[0].webSocketDebuggerUrl) 'Page.reload' @{ignoreCache=$true}
Say 'RECUPERACION_EMITIDA Page.reload sobre unica pestaña ChatGPT Images / Chrome 9234'
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{ $_.id -eq $gallery[0].id -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
if(-not $still.Count){
 Say 'AVISO galeria aun no confirmada tras recarga; no se lanza ninguna tarea adicional'
 return
}
Say 'GALERIA9234 PESTANA DISPONIBLE; el visor deberia estar cerrado'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
){
      try{
        $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5)
        $oldAlive=@($list|Where-Object{$_.id -eq $oldId})
        $newAlive=@($list|Where-Object{$_.id -eq $newId})
        if($oldAlive.Count -and $newAlive.Count){
          [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+$newId) -TimeoutSec 5)
          Say 'ROLLBACK_HTTP nueva pestana retirada; galeria anterior conservada'
        }
      }catch{Say ('ROLLBACK_HTTP_AVISO '+$_.Exception.Message)}
    }
    throw
  }
}
Say ('INICIO '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if(-not(Test-Path -LiteralPath $report)){throw 'No existe el informe de captura; no se puede asegurar el motivo del bloqueo'}
$reportFile=Get-Item -LiteralPath $report
$age=((Get-Date)-$reportFile.LastWriteTime).TotalMinutes
$doc=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
$reason=[string]$doc.error
Say ('INFORME '+$reportFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+' antiguedad_min='+[int]$age+' error='+$reason)
if($age -lt 0 -or $age -gt 45 -or $reason -notmatch 'Visor ya abierto al iniciar'){
 Say 'SIN_ACCION informe no reciente o ya no indica visor bloqueado'
 return
}
$running=@(Get-CimInstance Win32_Process |Where-Object{
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
if($running.Count){
 Say ('SIN_ACCION captura en curso PID='+($running.ProcessId -join ','))
 return
}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -eq 'Running'){
 Say 'SIN_ACCION tarea de captura ejecutandose actualmente'
 return
}
if($task.State -ne 'Ready'){throw ('Tarea '+$taskName+' no lista: '+$task.State)}
$targets=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$gallery=@($targets|Where-Object{
  $_.type -eq 'page' -and
  ([string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)') -and
  [string]$_.webSocketDebuggerUrl -match '^ws://(?:127\.0\.0\.1|localhost):9234/'
})
Say ('CHROME9234 paginas='+$targets.Count+' galerias='+$gallery.Count)
if($gallery.Count -ne 1){
 Say 'SIN_ACCION no hay una unica galeria /images identificable; no se toca ningun navegador'
 return
}
if($InspectOnly){
 Say ('SOLO_DIAGNOSTICO visor probable en '+$gallery[0].url)
 return
}
# The viewer is a modal inside the /images SPA. Reload ONLY that dedicated
# gallery tab: it does not close the browser or modify image-delivery state.
$result=ReadCDP ([string]$gallery[0].webSocketDebuggerUrl) 'Page.reload' @{ignoreCache=$true}
Say 'RECUPERACION_EMITIDA Page.reload sobre unica pestaña ChatGPT Images / Chrome 9234'
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{ $_.id -eq $gallery[0].id -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
if(-not $still.Count){
 Say 'AVISO galeria aun no confirmada tras recarga; no se lanza ninguna tarea adicional'
 return
}
Say 'GALERIA9234 PESTANA DISPONIBLE; el visor deberia estar cerrado'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -like '*relay-captura.js*')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
