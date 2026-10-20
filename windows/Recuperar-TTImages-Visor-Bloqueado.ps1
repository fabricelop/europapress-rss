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
    if([int]$data.id -ne 71){throw 'CDP devolvio evento inesperado'}
    if($data.error){throw ('CDP Error '+$data.error.message)}
    return $data.result
  }finally{
    try{$c.Dispose()}catch{}
    try{$timeout.Dispose()}catch{}
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
