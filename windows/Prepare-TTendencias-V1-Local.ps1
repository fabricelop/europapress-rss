# Paso previo a la retirada de TTendencias V1 en el ordenador.
# Actualiza el autoactualizador compartido y el receptor movil opcional.
# No desactiva tareas ni detiene trabajos en curso.
param([string]$RepoRoot='C:\TTiTTulares')
$ErrorActionPreference='Stop'
$marker='TTENDENCIAS_V1_RETIRE_GUARD'
$watchdog=Join-Path $RepoRoot 'TT-LocalWatchdog.ps1'
$listener=Join-Path $RepoRoot 'TTendenciasDedicatedListener.ps1'
$saveRoot=Join-Path $RepoRoot 'TTendencias-V1-Retirement'
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){throw 'No se encuentra la instalacion antigua.'}
foreach($path in @($watchdog,$listener)){
  if(-not (Test-Path -LiteralPath $path)){throw ('Falta '+[IO.Path]::GetFileName($path))}
  if(-not [IO.File]::ReadAllText($path).Contains($marker)){
    throw ('La proteccion todavia no ha llegado a '+[IO.Path]::GetFileName($path)+'. Espera unos minutos y repite; no se ha cambiado nada.')
  }
}
$names=@('TT-AutoUpdater.ps1','TTendenciasMobileChatTriggerListener.ps1')
$updated=0
foreach($name in $names){
  $target=Join-Path $RepoRoot $name
  if($name -eq 'TTendenciasMobileChatTriggerListener.ps1' -and -not (Test-Path -LiteralPath $target)){continue}
  if(Test-Path -LiteralPath $target){
    if([IO.File]::ReadAllText($target).Contains($marker)){continue}
  }
  $uri='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/'+$name
  $tmp=Join-Path ([IO.Path]::GetTempPath()) ('tt-v1-retire-'+[guid]::NewGuid().ToString('N')+'.ps1')
  try{
    Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $tmp -TimeoutSec 25 -Headers @{'Cache-Control'='no-cache'} -ErrorAction Stop|Out-Null
    $content=[IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
    if(-not $content.Contains($marker)){throw ('La proteccion de '+$name+' todavia no esta en main; sin cambios en ese archivo.')}
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count -gt 0){throw ('La version recibida no es valida: '+$errors[0].Message)}
    New-Item -Path $saveRoot -ItemType Directory -Force|Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    if(Test-Path -LiteralPath $target){
      Copy-Item -LiteralPath $target -Destination (Join-Path $saveRoot ($name+'-before-retirement-'+$stamp+'.bak')) -ErrorAction Stop
    }
    Copy-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop
    $updated++
    Write-Host ('TT_V1_PREPARED_FILE='+$name)
  }finally{
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}
Write-Host ('TT_V1_PREPARED_FILES='+$updated)
Write-Host 'TT_V1_SHARED_UPDATER_PREPARED=YES'
Write-Host 'TT_V1_PREPARATION_READY=YES'
Write-Host 'TT_V1_NEXT_STEP=Disable-TTendencias-V1-Local.ps1 -Action Disable'
# Los procesos ya abiertos se cierran durante la retirada, pero nunca se
# interrumpe el actualizador porque da servicio tambien a TTiTTulares.
