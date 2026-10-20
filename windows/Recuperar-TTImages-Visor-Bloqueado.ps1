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
# CDP HTTP fallback: create a clean /images tab before closing the stuck one.
# Keep all other Chrome 9234 tabs intact. Never touch Chrome 9223.
function RecoverGalleryByHttp([string]$oldId){
  if([string]::IsNullOrWhiteSpace($oldId) -or $oldId -notmatch '^[A-Za-z0-9_-]{1,160}
  $base='http://127.0.0.1:9234'
  $newId=''
  try {
    $created=Invoke-RestMethod -Method Put -Uri ($base+'/json/new?'+[Uri]::EscapeDataString('https://chatgpt.com/images')) -TimeoutSec 10 -ErrorAction Stop
    $newId=[string]$created.id
    if($newId -notmatch '^[A-Za-z0-9_-]{1,160}$' -or $newId -eq $oldId){throw 'Nueva galeria sin ID valido'}
    # New tabs can briefly report about:blank before /images navigates.
    $old=@();$fresh=@()
    for($probe=0;$probe -lt 8;$probe++){
      $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5 -ErrorAction Stop)
      $old=@($list|Where-Object{$_.id -eq $oldId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
      $fresh=@($list|Where-Object{$_.id -eq $newId -and $_.type -eq 'page'})
      if($old.Count -eq 1 -and $fresh.Count -eq 1 -and
         [string]$fresh[0].url -match '^https://chatgpt\.com/images(?:[/?#]|$)'){break}
      Start-Sleep -Milliseconds 600
    }
    if($old.Count -ne 1 -or $fresh.Count -ne 1 -or
       [string]$fresh[0].url -notmatch '^https://chatgpt\.com/images(?:[/?#]|$)'){
      throw 'No se verificaron ambas galerias; la original permanece intacta'
    }
    [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($oldId)) -TimeoutSec 8 -ErrorAction Stop)
    $closed=$false
    for($i=0;$i -lt 5;$i++){
      Start-Sleep -Milliseconds 650
      $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5 -ErrorAction Stop)
      $oldAlive=@($list|Where-Object{$_.id -eq $oldId})
      $newAlive=@($list|Where-Object{$_.id -eq $newId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
      if($oldAlive.Count -eq 0 -and $newAlive.Count -eq 1){$closed=$true;break}
    }
    if(-not $closed){throw 'Cierre del visor anterior no confirmado'}
    Say 'RECUPERACION_HTTP_OK galeria nueva disponible y visor viejo cerrado'
    return $newId
  }catch{
    if($newId -match '^[A-Za-z0-9_-]{1,160}$'){
      try {
        $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5)
        $oldAlive=@($list|Where-Object{$_.id -eq $oldId})
        $newAlive=@($list|Where-Object{$_.id -eq $newId})
        if($oldAlive.Count -gt 0 -and $newAlive.Count -gt 0){
          [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($newId)) -TimeoutSec 5)
          Say 'ROLLBACK_HTTP nueva pestana cerrada; galeria vieja conservada'
        }
      }catch {Say ('ROLLBACK_HTTP_AVISO '+$_.Exception.Message)}
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
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)')
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
$ws=[string]$gallery[0].webSocketDebuggerUrl
# Windows .NET can resolve localhost to IPv6 while Chrome listens on IPv4.
$ws=$ws -replace '^ws://localhost:9234/','ws://127.0.0.1:9234/'
$expectedId=[string]$gallery[0].id
try {
  [void](ReadCDP $ws 'Page.reload' @{ignoreCache=$true})
  Say 'RECUPERACION_WS_OK galeria recargada exclusivamente en Chrome 9234'
}catch{
  Say ('WEBSOCKET_NO_DISPONIBLE '+$_.Exception.Message.Split([char]10)[0])
  Say 'FALLBACK_HTTP creando galeria nueva en Chrome 9234'
  $targetId=[string]$gallery[0].id
  Say ('FALLBACK_HTTP target-id-longitud='+$targetId.Length)
  $expectedId=RecoverGalleryByHttp $targetId
}
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{
  $_.id -eq $expectedId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'
})
if($still.Count -ne 1){
  Say 'AVISO galeria no confirmada; se omite la tarea'
  return
}
Say 'GALERIA9234 LIMPIA DISPONIBLE; aun falta comprobar descarga y envio reales'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
){throw ('ID no valido para galeria longitud='+$oldId.Length)}
  # Validate by EXACT membership in Chrome's live target list.
  $liveBefore=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5 -ErrorAction Stop)
  $exact=@($liveBefore|Where-Object{[string]$_.id -ceq $oldId -and $_.type -eq 'page' -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
  if($exact.Count -ne 1){throw 'ID de galeria no coincide con Chrome 9234; no se toca ninguna pestana'}
  $base='http://127.0.0.1:9234'
  $newId=''
  try {
    $created=Invoke-RestMethod -Method Put -Uri ($base+'/json/new?'+[Uri]::EscapeDataString('https://chatgpt.com/images')) -TimeoutSec 10 -ErrorAction Stop
    $newId=[string]$created.id
    if($newId -notmatch '^[A-Za-z0-9_-]{1,160}$' -or $newId -eq $oldId){throw 'Nueva galeria sin ID valido'}
    # New tabs can briefly report about:blank before /images navigates.
    $old=@();$fresh=@()
    for($probe=0;$probe -lt 8;$probe++){
      $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5 -ErrorAction Stop)
      $old=@($list|Where-Object{$_.id -eq $oldId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
      $fresh=@($list|Where-Object{$_.id -eq $newId -and $_.type -eq 'page'})
      if($old.Count -eq 1 -and $fresh.Count -eq 1 -and
         [string]$fresh[0].url -match '^https://chatgpt\.com/images(?:[/?#]|$)'){break}
      Start-Sleep -Milliseconds 600
    }
    if($old.Count -ne 1 -or $fresh.Count -ne 1 -or
       [string]$fresh[0].url -notmatch '^https://chatgpt\.com/images(?:[/?#]|$)'){
      throw 'No se verificaron ambas galerias; la original permanece intacta'
    }
    [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($oldId)) -TimeoutSec 8 -ErrorAction Stop)
    $closed=$false
    for($i=0;$i -lt 5;$i++){
      Start-Sleep -Milliseconds 650
      $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5 -ErrorAction Stop)
      $oldAlive=@($list|Where-Object{$_.id -eq $oldId})
      $newAlive=@($list|Where-Object{$_.id -eq $newId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'})
      if($oldAlive.Count -eq 0 -and $newAlive.Count -eq 1){$closed=$true;break}
    }
    if(-not $closed){throw 'Cierre del visor anterior no confirmado'}
    Say 'RECUPERACION_HTTP_OK galeria nueva disponible y visor viejo cerrado'
    return $newId
  }catch{
    if($newId -match '^[A-Za-z0-9_-]{1,160}$'){
      try {
        $list=@(Invoke-RestMethod -Uri ($base+'/json/list') -TimeoutSec 5)
        $oldAlive=@($list|Where-Object{$_.id -eq $oldId})
        $newAlive=@($list|Where-Object{$_.id -eq $newId})
        if($oldAlive.Count -gt 0 -and $newAlive.Count -gt 0){
          [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($newId)) -TimeoutSec 5)
          Say 'ROLLBACK_HTTP nueva pestana cerrada; galeria vieja conservada'
        }
      }catch {Say ('ROLLBACK_HTTP_AVISO '+$_.Exception.Message)}
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
  $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)')
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
$ws=[string]$gallery[0].webSocketDebuggerUrl
# Windows .NET can resolve localhost to IPv6 while Chrome listens on IPv4.
$ws=$ws -replace '^ws://localhost:9234/','ws://127.0.0.1:9234/'
$expectedId=[string]$gallery[0].id
try {
  [void](ReadCDP $ws 'Page.reload' @{ignoreCache=$true})
  Say 'RECUPERACION_WS_OK galeria recargada exclusivamente en Chrome 9234'
}catch{
  Say ('WEBSOCKET_NO_DISPONIBLE '+$_.Exception.Message.Split([char]10)[0])
  Say 'FALLBACK_HTTP creando galeria nueva en Chrome 9234'
  $expectedId=RecoverGalleryByHttp ([string]$gallery[0].id)
}
Start-Sleep -Seconds 3
$after=@(Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/list' -TimeoutSec 5)
$still=@($after|Where-Object{
  $_.id -eq $expectedId -and [string]$_.url -match '^https://chatgpt\.com/images(?:[/?#]|$)'
})
if($still.Count -ne 1){
  Say 'AVISO galeria no confirmada; se omite la tarea'
  return
}
Say 'GALERIA9234 LIMPIA DISPONIBLE; aun falta comprobar descarga y envio reales'
if($NoTaskStart){
 Say 'SIN_LANZAR_TAREA espera ciclo programado de 5 minutos'
 return
}
$runningAgain=@(Get-CimInstance Win32_Process|Where-Object{
 $_.Name -match '^node(?:\.exe)?$' -and ([string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)')
})
$taskAgain=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($runningAgain.Count -or $taskAgain.State -ne 'Ready'){
 Say 'NO_FORZAR_CICLO ya hay proceso de captura o tarea no disponible'
 return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO mediante tarea existente; no prueba descarga ni envio'
Say 'FIN sin cambios en baseline, originales, Telegram o Chrome 9223'
