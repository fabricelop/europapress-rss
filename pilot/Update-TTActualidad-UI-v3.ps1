#requires -Version 5.1
# Update ONLY the static UI of the already-isolated TTActualidad pilot.
# No new Cloudflare resource, browser process, listener or scheduled task.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$worker=Join-Path $root 'ttactualidad-worker.js'
$site=Join-Path $root 'site\index.html'
$version='ae6d3bea1fa91d4bb2ac420f3ac40a668255ea02'
$raw='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$version+'/docs/index.html'
$target='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V3: ACTUALIZAR SOLO INTERFAZ DEL PILOTO ===' -ForegroundColor Cyan
foreach($file in @($config,$wrangler,$worker,$site)){
 if(!(Test-Path -LiteralPath $file)){throw ('No se encuentra archivo piloto necesario: '+$file)}
}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or
 @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
 [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion Cloudflare no corresponde al piloto aislado. No se despliega.'
}
$health=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 25
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false){
 throw 'El Worker no confirma modo piloto aislado. No se despliega.'
}
$workerSource=[IO.File]::ReadAllText($worker,[Text.Encoding]::UTF8)
if(!$workerSource.Contains('env.ASSETS.fetch(req)') -or !$workerSource.Contains('on_demand_no_polling')){
 throw 'La version Worker local no es V2 estable. No se despliega.'
}
$temp=Join-Path $root 'ttactualidad-v3-download.html'
Invoke-WebRequest -UseBasicParsing -Uri ($raw+'?version='+$version) -OutFile $temp -TimeoutSec 60
$html=[IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
$expected=[ordered]@{
 'Boton TTImages'=$html.Contains('id="ttimages-open"')
 'Enlace TTImages validado'=$html.Contains('function telegramChatUrl(raw)')
 'Sin boton inutil'=-not $html.Contains("btn('Dejar elaborar'")
 'Sin accion Ya publicada'=-not $html.Contains("command('Ya publicada'")
 'Unica retirada de Listas'=$html.Contains("command('Quitar de Listas','deleted')")
 'Acciones autentificadas'=$html.Contains('if(!pilotConfig())return')
 'Publicar en X'=$html.Contains("link('Publicar en X'")
}
$missing=@($expected.Keys|Where-Object{-not $expected[$_]})
if($missing.Count){
 foreach($item in $missing){Write-Warning ('Validacion V3: '+$item)}
 throw 'Interfaz descargada no coincide con V3. No se despliega.'
}
$jsStart=$html.IndexOf('<script>')
$jsEnd=$html.IndexOf('</script>',$jsStart)
if($jsStart -lt 0 -or $jsEnd -le $jsStart){throw 'No hay script JS en la interfaz V3.'}
$jsFile=Join-Path $root 'ttactualidad-v3-inline-check.js'
[IO.File]::WriteAllText($jsFile,$html.Substring($jsStart+8,$jsEnd-$jsStart-8),([Text.UTF8Encoding]::new($false)))
try {
 & node.exe --check $jsFile
 if($LASTEXITCODE -ne 0){throw 'JavaScript de TTActualidad V3 invalido.'}
} finally {
 Remove-Item -LiteralPath $jsFile -Force -ErrorAction SilentlyContinue
}
$backup=Join-Path $root 'index.before-v3.bak'
Copy-Item -LiteralPath $site -Destination $backup -Force
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
Push-Location $root
try{
 $prior=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $code=$LASTEXITCODE
 } finally {$ErrorActionPreference=$prior}
 if($code -ne 0){throw ('Wrangler no ha podido desplegar el Worker de prueba, codigo '+$code)}
} finally {Pop-Location}
Write-Host '=== VERIFICACION REMOTA DE LA INTERFAZ ===' -ForegroundColor Cyan
$ready=$false
for($i=1;$i -le 10;$i++){
 try{
  $page=Invoke-WebRequest -UseBasicParsing -Uri ($target+'?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($page.StatusCode -eq 200 -and $page.Content.Contains('id="ttimages-open"') -and
     $page.Content.Contains("command('Quitar de Listas','deleted')")){$ready=$true;break}
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$ready){throw 'Despliegue realizado, pero la web remota aun no confirma V3. No se modifica produccion.'}
$health=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 25
if(!$health.ok -or $health.production_connected -ne $false){throw 'Worker no confirma piloto aislado tras el despliegue.'}
Write-Host 'V3 OK: boton TTImages, un unico Quitar de Listas, sin Dejar elaborar.' -ForegroundColor Green
Write-Host 'TTImages: el primer uso pide el enlace exacto de Telegram, se guarda en el iPhone.'
Write-Host 'Cloudflare: sin recursos nuevos ni consultas periodicas. Produccion: SIN CAMBIOS.'
Write-Host ('Abre en iPhone: '+$target)
