# Reparacion aislada del recibo de imagenes REI-IA.
# Descarga archivos inmutables, drena solo el consumidor de imagenes V2,
# conserva originales y restaura siempre la tarea/flag anterior.
[CmdletBinding()]
param(
  [ValidateRange(5,60)][int]$MaxWaitMinutes=30,
  [switch]$SkipRecovery
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$root=Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$taskName='TTActualidadV2-Images-Auto'
$flag=Join-Path $root 'auto-images-v2.enabled'
$commit='1529f64dff3f88caa1bfcfcdb4d8ddb0972b1924'
$source='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$commit+'/v2/ttendencias/'
$checks=@{
  'image_worker_v2.py'='0e3d95b87b1d77062e5cb1eda322180714914bf0'
  'recover_image_receipts_v2.py'='660f6c75f58f00b463ca048a6dc41292a4d00a48'
}
$names=@('image_worker_v2.py','recover_image_receipts_v2.py')
$py=(Get-Command py.exe -ErrorAction Stop).Source
if(-not (Test-Path -LiteralPath $root -PathType Container)){
  throw 'Falta la instalacion de Tendencias V2; no se cambia nada'
}
if(-not (Test-Path -LiteralPath (Join-Path $root 'image_worker_v2.py') -PathType Leaf)){
  throw 'No se encuentra el consumidor de imagenes V2; no se cambia nada'
}

function GitBlobSha([byte[]]$bytes){
  $prefix=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $sha1=[Security.Cryptography.SHA1]::Create()
  try{return ([BitConverter]::ToString($sha1.ComputeHash([byte[]]($prefix+$bytes)))).Replace('-','').ToLowerInvariant()}
  finally{$sha1.Dispose()}
}

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stage=Join-Path $root ('REI-IA-receipt-preparado-'+$stamp)
$backup=Join-Path $root ('Backup-REI-IA-receipt-'+$stamp)
New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
$initial=@{}
$headers=@{'User-Agent'='TTActualidadV2-REI-IA-Receipt-Fix'}
foreach($name in $names){
  $dest=Join-Path $stage $name
  $target=Join-Path $root $name
  $initial[$name]=if(Test-Path -LiteralPath $target -PathType Leaf){
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  }else{$null}
  Invoke-WebRequest -Uri ($source+$name) -Headers $headers -UseBasicParsing -OutFile $dest
  if((GitBlobSha ([IO.File]::ReadAllBytes($dest))) -ne $checks[$name]){
    throw ('Descarga de imagenes no verificada: '+$name)
  }
  $parse=Start-Process -FilePath $py -ArgumentList @('-3','-m','py_compile',('"'+$dest+'"')) -Wait -PassThru -WindowStyle Hidden
  if($parse.ExitCode -ne 0){throw ('Python rechazo la descarga de '+$name)}
}

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskWasEnabled=($null -ne $task -and [string]$task.State -ne 'Disabled')
$flagExisted=Test-Path -LiteralPath $flag -PathType Leaf
$oldFlag=if($flagExisted){[IO.File]::ReadAllBytes($flag)}else{$null}
$wasGenerating=$flagExisted -and ([Text.Encoding]::UTF8.GetString($oldFlag) -match 'TT_V2_AUTO_IMAGES_ENABLED=YES')
$changed=@()
$draining=$false
$rollbackOK=$true
$success=$false
try{
  if($taskWasEnabled){Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop|Out-Null}
  [IO.File]::WriteAllText($flag,'TT_V2_AUTO_IMAGES_ENABLED=NO'+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
  $draining=$true
  $until=(Get-Date).AddMinutes($MaxWaitMinutes)
  do{
    $active=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
      $_.Name -match '^(?:py|python|pythonw)\.exe$' -and $_.CommandLine -and
      ([string]$_.CommandLine) -match '(?:image_daemon_v2|image_worker_v2)\.py'
    })
    if($active.Count -eq 0){break}
    if((Get-Date) -ge $until){throw 'Quedan imagenes en proceso; no se cambia ningun archivo'}
    Write-Host ('TT_V2_IMAGE_RECEIPT_WAITING='+$active.Count)
    Start-Sleep -Seconds 10
  }while($true)

  New-Item -ItemType Directory -Path $backup -ErrorAction Stop|Out-Null
  foreach($name in $names){
    $target=Join-Path $root $name
    $expectedOld=$initial[$name]
    if($null -ne $expectedOld){
      if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or
         (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $expectedOld){
        throw ('El modulo local ha cambiado; no reemplazar: '+$name)
      }
      Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name) -ErrorAction Stop
    }elseif(Test-Path -LiteralPath $target){
      throw ('Ha aparecido otro modulo local durante la espera: '+$name)
    }
  }
  foreach($name in $names){
    $changed+= $name
    Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $root $name) -Force -ErrorAction Stop
    if((GitBlobSha ([IO.File]::ReadAllBytes((Join-Path $root $name)))) -ne $checks[$name]){
      throw ('No se verifico el archivo instalado: '+$name)
    }
  }
  $success=$true
  if(-not $SkipRecovery){
    try{
      & $py -3 (Join-Path $root 'recover_image_receipts_v2.py') --apply
      if($LASTEXITCODE -ne 0){Write-Warning 'Recuperacion incompleta; el consumidor ya esta reparado'}
    }catch{
      Write-Warning 'La recuperacion no se ha completado; los originales permanecen guardados'
    }
  }
}catch{
  foreach($name in $changed){
    $target=Join-Path $root $name
    try{
      if($null -ne $initial[$name]){
        Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $target -Force -ErrorAction Stop
      }else{
        Remove-Item -LiteralPath $target -Force -ErrorAction Stop
      }
    }catch{
      $rollbackOK=$false
      Write-Warning ('No se pudo restaurar '+$name+'; tarea de imagenes desactivada por seguridad')
    }
  }
  throw
}finally{
  if($draining -and $rollbackOK){
    if($flagExisted){[IO.File]::WriteAllBytes($flag,$oldFlag)}
    else{Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue}
  }
  if($taskWasEnabled -and $rollbackOK){Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop|Out-Null}
}
if($success){
  if($wasGenerating -and $taskWasEnabled){Start-ScheduledTask -TaskName $taskName -ErrorAction Stop}
  Write-Host 'TT_V2_IMAGE_RECEIPT_REPAIRED=YES'
  Write-Host ('TT_V2_IMAGE_RECEIPT_BACKUP='+$backup)
  Write-Host ('TT_V2_IMAGE_RECEIPT_COMMIT='+$commit)
  Write-Host 'TT_V2_EDITORIAL_NEWS_V1=UNTOUCHED'
}
