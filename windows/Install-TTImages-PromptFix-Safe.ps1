#requires -Version 5.1
# TTImages: install only the two validated ChatGPT prompt bridges.
# Does NOT restart Chrome (9223/9234), TTImageRelay, listeners, tasks or send messages.
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root='C:\TTiTTulares'
$pin='ada8154710cfffee0f36263a957dca6b6d2c76db'
$names=@('TTiTTularesImageBridge.js','TTendenciasImageBridge.js')
$node=Get-Command node.exe -ErrorAction SilentlyContinue
if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
if(-not $node){throw 'Node.js no disponible; sin cambios'}
if(-not (Test-Path -LiteralPath $root)){throw 'No existe C:\TTiTTulares; sin cambios'}
$processes=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{
   $_.Name -match '^node(\.exe)?$' -and
   ([string]$_.CommandLine -like '*TTiTTularesImageBridge.js*' -or
    [string]$_.CommandLine -like '*TTendenciasImageBridge.js*')
})
if($processes.Count){throw 'Hay una imagen en proceso. No se modifica ningún archivo.'}
$temp=Join-Path $env:TEMP ('ttimage-prompt-fix-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$backups=@{}
$changed=@()
try {
  $downloads=@{}
  foreach($name in $names){
    $target=Join-Path $root $name
    if(-not (Test-Path -LiteralPath $target)){throw ('Falta el bridge instalado: '+$name)}
    $download=Join-Path $temp $name
    $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/windows/'+$name
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $download -TimeoutSec 40 -Headers @{'Cache-Control'='no-cache';'User-Agent'='TTImages-safe-prompt-fix'}
    if((Get-Item -LiteralPath $download).Length -lt 15000){throw ('Descarga incompleta: '+$name)}
    $text=[IO.File]::ReadAllText($download,[Text.Encoding]::UTF8)
    foreach($marker in @('data-tt-image-composer','prompt_not_in_visible_editor','function submissionEvidence(','post-send-generation','async function submitVerifiedDraft(','BRIDGE FIXED TAB UNRESPONSIVE','if(!launchOnly)throw Error','await confirmPromptLaunched()')){
      if(-not $text.Contains($marker)){throw ('Falta garantía '+$marker+' en '+$name)}
    }
    & $node.Source --check $download
    if($LASTEXITCODE -ne 0){throw ('Sintaxis inválida: '+$name)}
    $downloads[$name]=$download
    $localSha=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $remoteSha=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
    Write-Host ($name+': '+$(if($localSha -eq $remoteSha){'ACTUALIZADO'}else{'REQUIERE ACTUALIZAR'}))
  }
  if($CheckOnly){Write-Host 'Comprobación completada: sin modificaciones';return}
  # No replace if a dedicated bridge started after the first check.
  $active=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object{
    $_.Name -match '^node(\.exe)?$' -and
    ([string]$_.CommandLine -like '*TTiTTularesImageBridge.js*' -or
     [string]$_.CommandLine -like '*TTendenciasImageBridge.js*')
  })
  if($active.Count){throw 'Un bridge se ha iniciado mientras se verificaba. Sin modificaciones.'}
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach($name in $names){
    $target=Join-Path $root $name
    $localSha=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $newSha=(Get-FileHash -LiteralPath $downloads[$name] -Algorithm SHA256).Hash
    if($localSha -eq $newSha){continue}
    $backup=Join-Path $root ($name+'.before-promptfix-'+$stamp+'.bak')
    Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
    $backups[$target]=$backup
    Copy-Item -LiteralPath $downloads[$name] -Destination $target -Force -ErrorAction Stop
    if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $newSha){
      throw ('Hash de destino incorrecto: '+$name)
    }
    $changed+= $name
  }
  Write-Host ('TTImages prompt fix instalado. Bridges actualizados: '+$changed.Count) -ForegroundColor Green
  Write-Host 'No se han reiniciado Chrome, TTImageRelay ni los listeners.'
  Write-Host 'Las órdenes antiguas agotadas requieren una reencolación controlada posterior.'
}catch{
  foreach($target in @($backups.Keys)){
    if(Test-Path -LiteralPath $backups[$target]){Copy-Item -LiteralPath $backups[$target] -Destination $target -Force}
  }
  throw
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
