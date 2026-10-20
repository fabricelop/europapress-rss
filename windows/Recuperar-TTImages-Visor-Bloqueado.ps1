#requires -Version 5.1
<#
TTImages v2.7 - recover an orphaned ChatGPT Images viewer in Chrome 9234 only.
Chrome /json/list is a JSON ARRAY: parse each target separately. Do not wrap
Invoke-RestMethod directly in @(), which can treat the array as one object.
No modification to existing images, deduplication baseline, bot or Chrome 9223.
#>
param([switch]$InspectOnly,[switch]$NoTaskStart)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$base='http://127.0.0.1:9234'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
$report=Join-Path $root 'informe-captura-v2.json'
$taskName='TT Image Relay - Telegram v2'
$galleryPattern='^https://chatgpt\.com/images(?:[/?#]|$)'
function Say([string]$message){Write-Host ('TTIMAGES_V27 '+$message)}
function GetChromeTargets {
  $response=Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/list') -TimeoutSec 8 -ErrorAction Stop
  $doc=ConvertFrom-Json -InputObject ([string]$response.Content) -ErrorAction Stop
  # Force a FLAT array with independently addressable Chrome target records.
  $targets=@($doc)
  if($targets.Count -lt 1 -or $targets.Count -gt 100){throw ('Numero inusual de targets='+$targets.Count)}
  foreach($target in $targets){
    if($target -is [array] -or $target -isnot [psobject]){
      throw 'Chrome devolvio targets agrupados o JSON no valido. Sin cambios.'
    }
    if([string]::IsNullOrWhiteSpace([string]$target.type) -or
       [string]::IsNullOrWhiteSpace([string]$target.url)){
      throw 'Target Chrome incompleto. Sin cambios.'
    }
  }
  return $targets
}
function GetGalleryTargets([object[]]$targets){
  return @($targets|Where-Object{
    [string]$_.type -ceq 'page' -and
    [string]$_.url -match $galleryPattern
  })
}
function CheckTargetId([string]$id){
  if([string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 256 -or
     $id -match '[\x00-\x1F\x7F/]'){
    throw 'Chrome devolvio un ID de pestaña no utilizable. Sin cambios.'
  }
}
function GetCaptureProcess {
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|
   Where-Object{
     $_.Name -match '^node(?:\.exe)?$' -and
     [string]$_.CommandLine -match '(?i)(relay-captura|TTImageRelay.*captura|TTImageRelay.*capture)'
   })
}
function EnsureIdle {
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if($task.State -ne 'Ready'){
    Say ('SIN_ACCION tarea ocupada/no disponible: '+$task.State)
    return $false
  }
  $p=@(GetCaptureProcess)
  if($p.Count -gt 0){
    Say ('SIN_ACCION capturador en marcha ('+$p.Count+' procesos)')
    return $false
  }
  return $true
}
Say ('INICIO '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if(-not(Test-Path -LiteralPath $report)){throw 'Informe de captura ausente. Sin cambios.'}
$info=Get-Item -LiteralPath $report
$minutes=((Get-Date)-$info.LastWriteTime).TotalMinutes
$reportData=Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
$errorText=[string]$reportData.error
Say ('INFORME '+$info.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+
 ' edad_min='+[int]$minutes+' error='+$errorText)
if($minutes -lt 0 -or $minutes -gt 45 -or
   $errorText -notmatch 'Visor ya abierto al iniciar|No hay exactamente una pesta'){
  Say 'SIN_ACCION el informe no confirma bloqueo reciente del visor/galeria'
  return
}
if(-not(EnsureIdle)){return}
$all=@(GetChromeTargets)
$galleries=@(GetGalleryTargets $all)
Say ('TARGETS_REALES '+$all.Count+' galerias_reales='+$galleries.Count)
$rank=0
foreach($t in $all){
  $rank++
  $kind=if([string]$t.url -match $galleryPattern){'GALERIA'}else{'OTRA'}
  $id=[string]$t.id
  Say ('TARGET '+$rank+' type='+[string]$t.type+' kind='+$kind+' id_chars='+$id.Length)
}
if($galleries.Count -gt 3){
  Say 'SIN_ACCION mas de tres galerias; revisar manualmente antes de cerrar ninguna'
  return
}
foreach($g in $galleries){CheckTargetId ([string]$g.id)}
if($InspectOnly){
  Say 'SOLO_LECTURA ninguna pestana modificada'
  return
}
# Create one clean /images tab first. Never close an existing tab until the
# new one is visible and ALL preexisting gallery targets are still present.
$newId=''
$oldIds=@($galleries|ForEach-Object{[string]$_.id})
$oldCount=$galleries.Count
$createdNew=$false
$closedAny=$false
try{
  $openUrl=$base+'/json/new?'+[Uri]::EscapeDataString('https://chatgpt.com/images')
  $new=Invoke-RestMethod -Method Put -Uri $openUrl -TimeoutSec 12 -ErrorAction Stop
  $newId=[string]$new.id
  CheckTargetId $newId
  if($oldIds -ccontains $newId){throw 'Chrome reuso ID de una pestaña anterior'}
  $createdNew=$true
  $verified=$false
  for($attempt=0;$attempt -lt 16;$attempt++){
    Start-Sleep -Milliseconds 750
    $allNow=@(GetChromeTargets)
    $newTarget=@($allNow|Where-Object{[string]$_.id -ceq $newId -and
      [string]$_.type -ceq 'page' -and [string]$_.url -match $galleryPattern})
    $oldNow=@($allNow|Where-Object{ $oldIds -ccontains ([string]$_.id) -and
      [string]$_.type -ceq 'page' -and [string]$_.url -match $galleryPattern })
    if($newTarget.Count -eq 1 -and $oldNow.Count -eq $oldCount){
      $verified=$true;break
    }
  }
  if(-not $verified){
    throw 'Galeria nueva y galerias anteriores no verificadas; no se cierran las anteriores'
  }
  Say ('GALERIA_NUEVA_CONFIRMADA anteriores='+$oldCount+' nueva_id_chars='+$newId.Length)
  # Recheck right before EACH close: close only an exact old /images target
  # and abort if the capture process has started in the meantime.
  foreach($id in $oldIds){
    if(-not(EnsureIdle)){throw 'Capturador iniciado durante la recuperacion'}
    $before=@(GetChromeTargets)
    $same=@($before|Where-Object{[string]$_.id -ceq $id -and
      [string]$_.type -ceq 'page' -and [string]$_.url -match $galleryPattern})
    $newExists=@($before|Where-Object{[string]$_.id -ceq $newId -and
      [string]$_.type -ceq 'page' -and [string]$_.url -match $galleryPattern})
    if($same.Count -ne 1 -or $newExists.Count -ne 1){
      throw 'Una pestaña cambio mientras se recuperaba; no cerrar otra'
    }
    [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($id)) -TimeoutSec 9 -ErrorAction Stop)
    $closedAny=$true
    Say 'GALERIA_ANTIGUA_CERRADA por ID verificado de Chrome 9234'
  }
  $good=$false
  for($verify=0;$verify -lt 9;$verify++){
    Start-Sleep -Milliseconds 700
    $final=@(GetChromeTargets)
    $actual=@(GetGalleryTargets $final)
    if($actual.Count -eq 1 -and [string]$actual[0].id -ceq $newId){$good=$true;break}
  }
  if(-not $good){throw 'No quedo exactamente una galeria nueva; NO se arranca captura'}
  Say 'RECUPERACION_HTTP_OK unica galeria limpia en Chrome 9234'
}catch{
  Say ('RECUPERACION_DETENIDA '+$_.Exception.Message)
  if($createdNew -and -not $closedAny){
    # Roll back only if old tabs are still present; never leave accidental
    # duplicates when no changes were made to the original viewer.
    try{
      $list=@(GetChromeTargets)
      $oldAlive=@($list|Where-Object{$oldIds -ccontains ([string]$_.id)})
      $newAlive=@($list|Where-Object{[string]$_.id -ceq $newId -and
        [string]$_.url -match $galleryPattern})
      if($oldAlive.Count -eq $oldCount -and $newAlive.Count -eq 1 -and $oldCount -gt 0){
        [void](Invoke-WebRequest -UseBasicParsing -Uri ($base+'/json/close/'+[Uri]::EscapeDataString($newId)) -TimeoutSec 8)
        Say 'ROLLBACK nueva galeria cerrada; antiguas conservadas'
      }
    }catch{Say ('ROLLBACK_AVISO '+$_.Exception.Message)}
  }
  return
}
if($NoTaskStart){
  Say 'SIN_TAREA esperar ciclo programado de TTImages'
  return
}
if(-not(EnsureIdle)){
  Say 'CAPTURA_NO_FORZADA otra instancia activa; se espera ciclo programado'
  return
}
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
Say 'CICLO_CAPTURA_SOLICITADO por tarea existente; comprobar descarga y Telegram despues'
Say 'FIN sin modificar baseline, originales, bot ni Chrome 9223'
