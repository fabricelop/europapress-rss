# Instalar solo el consumidor REI-IA de imágenes V2, nunca el editorial/Noticias.
# No aborta chats: deja agotar los trabajos activos y conserva originales.
[CmdletBinding()]
param([ValidateRange(5,60)][int]$MaxWaitMinutes=30)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$root=Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName='TTActualidadV2-Images-Auto'
$flag=Join-Path $root 'auto-images-v2.enabled'
$commit='2c820f5c426297455ee4281539a4ff50153ed437'
$repo='fabricelop/europapress-rss'
$names=@('image_worker_v2.py','image_daemon_v2.py')
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not (Test-Path -LiteralPath $root -PathType Container)){throw 'No existe la instalación de Tendencias V2'}
foreach($name in $names){
  if(-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)){
    throw ('Falta el módulo actual; no se ha modificado nada: '+$name)
  }
}

$headers=@{'User-Agent'='TTActualidadV2-REI-IA-safe-update';'Accept'='application/vnd.github+json'}
$api='https://api.github.com/repos/'+$repo
$raw='https://raw.githubusercontent.com/'+$repo+'/'+$commit+'/v2/ttendencias/'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stage=Join-Path $root ('REI-IA-preparado-'+$stamp)
$backup=Join-Path $root ('Backup-REI-IA-'+$stamp)
New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null

function GitBlobSha([byte[]]$bytes){
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $sha1=[Security.Cryptography.SHA1]::Create()
  try{return ([BitConverter]::ToString($sha1.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}
  finally{$sha1.Dispose()}
}

# Descargar y verificar todo ANTES de cambiar el estado de la tarea.
$expected=@{}
$originalHash=@{}
foreach($name in $names){
  $target=Join-Path $root $name
  $originalHash[$name]=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  $meta=Invoke-RestMethod -Uri ($api+'/contents/v2/ttendencias/'+$name+'?ref='+$commit) -Headers $headers
  $dest=Join-Path $stage $name
  Invoke-WebRequest -Uri ($raw+$name) -Headers $headers -UseBasicParsing -OutFile $dest
  if((GitBlobSha ([IO.File]::ReadAllBytes($dest))) -ne [string]$meta.sha){
    throw ('Descarga no verificada; no se ha tocado la instalación: '+$name)
  }
  $expected[$name]=[string]$meta.sha
  $check=Start-Process -FilePath $py -ArgumentList @('-3','-m','py_compile',('"'+$dest+'"')) -Wait -PassThru -WindowStyle Hidden
  if($check.ExitCode -ne 0){throw ('Python rechazó la nueva versión: '+$name)}
}

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskWasEnabled=($null -ne $task -and [string]$task.State -ne 'Disabled')
$flagExisted=Test-Path -LiteralPath $flag -PathType Leaf
$oldFlag=if($flagExisted){[IO.File]::ReadAllBytes($flag)}else{$null}
$wasGenerating=$flagExisted -and ([Text.Encoding]::UTF8.GetString($oldFlag) -match 'TT_V2_AUTO_IMAGES_ENABLED=YES')
$changed=@()
$draining=$false
$success=$false
$rollbackOK=$true
try{
  if($taskWasEnabled){Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null}
  [IO.File]::WriteAllText($flag,'TT_V2_AUTO_IMAGES_ENABLED=NO'+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
  $draining=$true
  $until=(Get-Date).AddMinutes($MaxWaitMinutes)
  do{
    $active=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
      $_.Name -match '^(?:py|python|pythonw)\.exe$' -and $_.CommandLine -and
      ([string]$_.CommandLine) -match '(?:image_daemon_v2|image_worker_v2)\.py'
    })
    if($active.Count -eq 0){break}
    if((Get-Date) -ge $until){throw 'REI-IA: siguen generándose imágenes; no se ha sustituido ningún archivo'}
    Write-Host ('TT_V2_REI_IA_WAITING_IMAGES='+$active.Count)
    Start-Sleep -Seconds 10
  }while($true)

  New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
  foreach($name in $names){
    $target=Join-Path $root $name
    if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $originalHash[$name]){
      throw ('El módulo local cambió durante la espera; no sobrescribir: '+$name)
    }
    Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name) -ErrorAction Stop
  }
  foreach($name in $names){
    $changed+= $name
    Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $root $name) -Force -ErrorAction Stop
  }
  foreach($name in $names){
    $target=Join-Path $root $name
    if((GitBlobSha ([IO.File]::ReadAllBytes($target))) -ne $expected[$name]){
      throw ('El archivo instalado no coincide con la versión comprobada: '+$name)
    }
  }
  $success=$true
}catch{
  foreach($name in $changed){
    $prior=Join-Path $backup $name
    try{
      if(-not (Test-Path -LiteralPath $prior)){throw ('Falta la copia de '+$name)}
      Copy-Item -LiteralPath $prior -Destination (Join-Path $root $name) -Force -ErrorAction Stop
    }catch{
      $rollbackOK=$false
      Write-Warning ('REI-IA: fallo al restaurar '+$name+'; la tarea de imágenes seguirá detenida')
    }
  }
  throw
}finally{
  if($draining -and $rollbackOK){
    if($flagExisted){[IO.File]::WriteAllBytes($flag,$oldFlag)}
    else{Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue}
  }
  if($taskWasEnabled -and $rollbackOK){Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null}
}
if($success){
  if($wasGenerating -and $taskWasEnabled){Start-ScheduledTask -TaskName $taskName -ErrorAction Stop}
  Write-Host 'TT_V2_REI_IA_INSTALLED=YES'
  Write-Host ('TT_V2_REI_IA_BACKUP='+$backup)
  Write-Host ('TT_V2_REI_IA_COMMIT='+$commit)
  Write-Host 'TT_V2_EDITORIAL_AND_NEWS=UNTOUCHED'
}
