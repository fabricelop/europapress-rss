#requires -Version 5.1
# Update ONLY the existing Cloudflare TTActualidad trial (never official GitHub Pages).
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$worker=Join-Path $root 'ttactualidad-worker.js'
$site=Join-Path $root 'site\index.html'
$version='2f494846223dd983a79538c8fc59b122ad50c35d'
$base='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$version+'/'
$target='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
if(!(Test-Path -LiteralPath $config) -or !(Test-Path -LiteralPath $wrangler)){
 throw 'No se encuentra el piloto previamente instalado. No se crearan recursos.'
}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$bindings=@($cfg.kv_namespaces|Where-Object {$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or
 @($cfg.kv_namespaces).Count -ne 1 -or $bindings.Count -ne 1 -or
 [string]$bindings[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion ajena al piloto o KV distinto. Detenido.'
}
$health=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 25
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false){
 throw 'La URL no responde como Worker de prueba; detenido.'
}
Write-Host '=== ACTUALIZAR SOLO WEB + WORKER DE PRUEBAS ===' -ForegroundColor Cyan
$wtemp=Join-Path $root 'ttactualidad-worker-check.mjs'
$htemp=Join-Path $root 'index-check.html'
Invoke-WebRequest -UseBasicParsing -Uri ($base+'pilot/ttactualidad-worker.js?source='+$version) -OutFile $wtemp -TimeoutSec 60
Invoke-WebRequest -UseBasicParsing -Uri ($base+'docs/index.html?source='+$version) -OutFile $htemp -TimeoutSec 60
$w=[IO.File]::ReadAllText($wtemp,[Text.Encoding]::UTF8)
$h=[IO.File]::ReadAllText($htemp,[Text.Encoding]::UTF8)
$checks=[ordered]@{
 'Worker V2 /health'=$w.Contains('on_demand_no_polling')
 'Worker assets publicos'=$w.Contains('env.ASSETS.fetch(req)')
 'Worker GitHub apagado por defecto'=$w.Contains("env.ACTION_MODE!=='github_dispatch'")
 'App TTActualidad'=$h.Contains('TTActualidad')
 'Acciones directas en interfaz'=$h.Contains('Conectar acciones directas')
 'Interfaz tarjetas V2'=$h.Contains('pilotSwipes(card,item)')
}
$invalid=@($checks.Keys | Where-Object {-not $checks[$_]})
if($invalid.Count){
 Write-Host ('Fuente descargada: commit '+$version)
 foreach($item in $invalid){Write-Warning ('Falta en descarga: '+$item)}
 Write-Host ('Bytes descargados: Worker '+$w.Length+', web '+$h.Length)
 throw 'Los archivos descargados no coinciden con la version fija. No se despliega.'
}
Write-Host ('Archivos V2 validados desde commit '+$version)
& node.exe --check $wtemp
if($LASTEXITCODE -ne 0){throw 'Worker JavaScript invalido'}
$jsStart=$h.IndexOf('<script>')
$jsEnd=$h.IndexOf('</script>',$jsStart)
if($jsStart -lt 0 -or $jsEnd -le $jsStart){throw 'Web sin JavaScript'}
$checkjs=Join-Path $root 'v2-inline-check.js'
[IO.File]::WriteAllText($checkjs,$h.Substring($jsStart+8,$jsEnd-$jsStart-8),([Text.UTF8Encoding]::new($false)))
try{
 & node.exe --check $checkjs
 if($LASTEXITCODE -ne 0){throw 'Interfaz JavaScript invalida'}
}finally{Remove-Item $checkjs -Force -ErrorAction SilentlyContinue}
if(Test-Path $worker){Copy-Item $worker (Join-Path $root 'worker.before-v2.bak') -Force}
if(Test-Path $site){Copy-Item $site (Join-Path $root 'index.before-v2.bak') -Force}
[IO.File]::WriteAllText($worker,$w,([Text.UTF8Encoding]::new($false)))
[IO.File]::WriteAllText($site,$h,([Text.UTF8Encoding]::new($false)))
Remove-Item $wtemp,$htemp -Force -ErrorAction SilentlyContinue
Push-Location $root
try{
 $prev=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $deployCode=$LASTEXITCODE
 }finally{$ErrorActionPreference=$prev}
 if($deployCode -ne 0){throw ('No se ha podido desplegar el Worker piloto, codigo '+$deployCode)}
}finally{Pop-Location}
Write-Host '=== COMPROBAR API V2 (SIN ORDENES REALES) ===' -ForegroundColor Cyan
$ok=$false
for($i=1;$i -le 8;$i++){
 try{
  $health=Invoke-RestMethod -Uri ($target+'health?verify='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
  if($health.ok -and $health.architecture -ceq 'on_demand_no_polling' -and $health.production_connected -eq $false){$ok=$true;break}
 }catch{}
 if($i -lt 8){Start-Sleep -Seconds 3}
}
if(!$ok){throw 'Despliegue realizado pero la nueva API aun no esta verificada. No cambies produccion.'}
Write-Host '=== VERIFICAR PAGINA PUBLICA EN PILOTO ===' -ForegroundColor Cyan
$siteOk=$false
for($i=1;$i -le 10;$i++){
 try{
  $page=Invoke-WebRequest -UseBasicParsing -Uri ($target+'?ui_check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($page.StatusCode -eq 200 -and $page.Content.Contains('Conectar acciones directas')){
   $siteOk=$true;break
  }
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$siteOk){throw 'La API V2 esta desplegada, pero la pagina aun no muestra la interfaz nueva. No se toca produccion.'}
Write-Host 'PILOTO V2: Worker actualizado. No se crearon KV, secretos, Chrome ni tareas.' -ForegroundColor Green
Write-Host ('Abre o recarga en el iPhone: '+$target)
Write-Host 'Las ordenes de las tarjetas SE REGISTRAN SOLO EN PRUEBAS; todavia no borran noticias reales.'
Write-Host 'Elige Listas o En elaboracion. Publicar en X abre el editor de X.'
