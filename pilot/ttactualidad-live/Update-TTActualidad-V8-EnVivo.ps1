#requires -Version 5.1
# TTActualidad V8 LIVE: actualiza solo los archivos del Worker existente.
# Conserva secrets, cookie 30 dias, KV y URL. No toca tareas Windows ni otras apps.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$pin = 'e2bbd2a8917418f9c2e19acfcebb2d3f25399aab'
$base = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/pilot/ttactualidad-live/'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V8: decisiones reales y Listas recientes ===' -ForegroundColor Cyan
foreach($f in @($config,$site,$worker,$wrangler)){
 if(!(Test-Path -LiteralPath $f)){throw ('Falta un archivo local obligatorio: '+$f)}
}
$cfg = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or
 @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
 [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion de Cloudflare distinta de la validada. No se despliega.'
}
$health = Invoke-RestMethod -Uri ($url+'health?t='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
if(!$health.ok -or $health.production_connected -ne $true -or
 $health.session_auth -cne 'signed_cookie_v1' -or
 @('isolated-ttactualidad-pilot','ttactualidad-direct-live') -cnotcontains [string]$health.kind){
 throw 'No se confirma la conexion REAL y la sesion segura actual. Sin cambios.'
}
$temp = Join-Path $root 'update-v8'
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$newUi = Join-Path $temp 'index.html'
$newWorker = Join-Path $temp 'worker.js'
Invoke-WebRequest -UseBasicParsing -Uri ($base+'index.html?pin='+$pin) -OutFile $newUi -TimeoutSec 60
Invoke-WebRequest -UseBasicParsing -Uri ($base+'worker.js?pin='+$pin) -OutFile $newWorker -TimeoutSec 60
$html = [IO.File]::ReadAllText($newUi,[Text.Encoding]::UTF8)
$js = [IO.File]::ReadAllText($newWorker,[Text.Encoding]::UTF8)
foreach($required in @('Pasar a En Elaboraci','current-explained>48*3600000',
 'https://t.me/TTImages_bot','function hideOptimistically','async function checkPendingDeletes',
 'function confirmedAction','grid-template-columns:repeat(2,minmax(0,1fr))')){
 if(!$html.Contains($required)){throw ('No coincide interfaz V8: '+$required)}
}
if($html.Contains('funciona este piloto?') -or $html.Contains('registrada en pruebas') -or
 $html.Contains('function pilotSwipes(')){throw 'UI contiene un comportamiento antiguo. No se despliega.'}
foreach($required in @("route==='/api/session'",'signed_cookie_v1',"['deleted','discard','prepare'].includes",
 'crypto.subtle.verify','ttactualidad-direct-live')){
 if(!$js.Contains($required)){throw ('No coincide Worker V8: '+$required)}
}
$start=$html.IndexOf('<script>');$end=$html.IndexOf('</script>',$start)
if($start -lt 0 -or $end -le $start){throw 'Script web V8 no encontrado'}
$uiCheck=Join-Path $temp 'ui-check.js'
$workerCheck=Join-Path $temp 'worker-check.mjs'
[IO.File]::WriteAllText($uiCheck,$html.Substring($start+8,$end-$start-8),([Text.UTF8Encoding]::new($false)))
[IO.File]::WriteAllText($workerCheck,$js,([Text.UTF8Encoding]::new($false)))
& node.exe --check $uiCheck
if($LASTEXITCODE -ne 0){throw 'La sintaxis de la interfaz V8 no es valida'}
& node.exe --check $workerCheck
if($LASTEXITCODE -ne 0){throw 'La sintaxis del Worker V8 no es valida'}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupUi = Join-Path $root ('index.before-v8-'+$stamp+'.bak')
$backupWorker = Join-Path $root ('worker.before-v8-'+$stamp+'.bak')
Copy-Item -LiteralPath $site -Destination $backupUi -Force
Copy-Item -LiteralPath $worker -Destination $backupWorker -Force
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
[IO.File]::WriteAllText($worker,$js,([Text.UTF8Encoding]::new($false)))
$code=-1
Push-Location $root
try{
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue'; & $wrangler deploy --config $config; $code=$LASTEXITCODE}
 finally{$ErrorActionPreference=$old}
}finally{Pop-Location}
if($code -ne 0){
 Copy-Item -LiteralPath $backupUi -Destination $site -Force
 Copy-Item -LiteralPath $backupWorker -Destination $worker -Force
 throw ('Wrangler fallo ('+$code+'). Archivos locales restaurados.')
}
$ok=$false
for($i=0;$i -lt 10;$i++){
 try{
  $h=Invoke-RestMethod -Uri ($url+'health?v8='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  $page=Invoke-WebRequest -UseBasicParsing -Uri ($url+'?v8='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($h.ok -and $h.kind -ceq 'ttactualidad-direct-live' -and $h.production_connected -eq $true -and
   $h.session_auth -ceq 'signed_cookie_v1' -and $page.StatusCode -eq 200 -and
   $page.Content.Contains('Pasar a En Elaboraci') -and
   $page.Content.Contains('current-explained>48*3600000')){$ok=$true;break}
 }catch{}
 if($i -lt 9){Start-Sleep -Seconds 3}
}
if(!$ok){throw 'Worker desplegado, pero verificacion V8 remota incompleta; no se declara exito. Revisa Cloudflare.'}
Write-Host 'V8 en produccion: Listas recientes, Desestimar real, Revisar a Elaboracion y confirmacion GitHub.' -ForegroundColor Green
Write-Host ('URL intacta: '+$url)
Write-Host 'Conservados: secrets, sesion iPhone, TTImages, SeLoRecordamos, Tremending y Chrome.'
Write-Host ('Respaldo: '+$backupUi)
