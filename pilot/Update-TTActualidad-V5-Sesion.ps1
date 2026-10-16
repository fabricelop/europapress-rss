#requires -Version 5.1
# Update existing TTActualidad pilot only: signed iPhone session + optimistic list removal.
# No new GitHub token, no new workers, no KV, no Chrome, no scheduled task.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$worker=Join-Path $root 'ttactualidad-worker.js'
$site=Join-Path $root 'site\index.html'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$version='a24d54c5c8de619ac6c77592aca40e69dc6c32ca'
$base='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$version+'/'
$target='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V5: SESION IPHONE + RETIRADA INMEDIATA ===' -ForegroundColor Cyan
foreach($file in @($config,$worker,$site,$wrangler)){
 if(!(Test-Path -LiteralPath $file)){throw ('Falta archivo del piloto: '+$file)}
}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object {$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or
 @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
 [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion ajena al piloto; no se despliega.'
}
$before=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 25
if(!$before.ok -or $before.kind -cne 'isolated-ttactualidad-pilot' -or
 $before.production_connected -ne $true){
 throw 'La retirada real no esta activa ANTES del cambio. No se altera el Worker.'
}
$tmpWorker=Join-Path $root 'v5-worker-check.mjs'
$tmpHtml=Join-Path $root 'v5-web-check.html'
Invoke-WebRequest -UseBasicParsing -Uri ($base+'pilot/ttactualidad-worker.js?v='+$version) -OutFile $tmpWorker -TimeoutSec 60
Invoke-WebRequest -UseBasicParsing -Uri ($base+'docs/index.html?v='+$version) -OutFile $tmpHtml -TimeoutSec 60
$jsWorker=[IO.File]::ReadAllText($tmpWorker,[Text.Encoding]::UTF8)
$html=[IO.File]::ReadAllText($tmpHtml,[Text.Encoding]::UTF8)
$checks=[ordered]@{
 'Sesion HttpOnly'=$jsWorker.Contains('HttpOnly; SameSite=Strict')
 'Firma de cookie'=$jsWorker.Contains("crypto.subtle.verify('HMAC'")
 'Autenticacion sin KV'=$jsWorker.Contains("route==='/api/auth'")
 'Emparejamiento puntual'=$jsWorker.Contains("route==='/api/session'")
 'Acciones directas'=$jsWorker.Contains('github_dispatch')
 'Ocultar inmediatamente'=$html.Contains('function hideOptimistically(item)')
 'Restaurar si falla'=$html.Contains('function restoreOptimistic(key,message)')
 'Comprobacion Github'=$html.Contains('async function checkPendingDeletes()')
 'Sesion en iPhone'=$html.Contains('async function ensurePilotConnection()')
 'TTImages fijo'=$html.Contains('https://t.me/TTImages_bot')
 'Cuatro filas dos columnas'=$html.Contains('grid-template-columns:repeat(2,minmax(0,1fr))')
 'Sin solicitud repetida de URL'=-not $html.Contains("prompt('URL HTTPS del Worker")
}
$bad=@($checks.Keys|Where-Object{-not $checks[$_]})
if($bad.Count){
 foreach($name in $bad){Write-Warning ('Falta '+$name)}
 throw 'Los ficheros V5 no coinciden; no se despliega.'
}
& node.exe --check $tmpWorker
if($LASTEXITCODE -ne 0){throw 'Worker V5 JS invalido'}
$start=$html.IndexOf('<script>')
$end=$html.IndexOf('</script>',$start)
if($start -lt 0 -or $end -le $start){throw 'Script V5 no encontrado'}
$check=Join-Path $root 'v5-web-check.js'
[IO.File]::WriteAllText($check,$html.Substring($start+8,$end-$start-8),([Text.UTF8Encoding]::new($false)))
try{
 & node.exe --check $check
 if($LASTEXITCODE -ne 0){throw 'Interfaz V5 JS invalida'}
}finally{Remove-Item $check -Force -ErrorAction SilentlyContinue}
Copy-Item $worker (Join-Path $root 'worker.before-v5.bak') -Force
Copy-Item $site (Join-Path $root 'index.before-v5.bak') -Force
[IO.File]::WriteAllText($worker,$jsWorker,([Text.UTF8Encoding]::new($false)))
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
Remove-Item $tmpWorker,$tmpHtml -Force -ErrorAction SilentlyContinue
Write-Host '=== DESPLEGAR SOLO WEB + WORKER YA EXISTENTES ===' -ForegroundColor Cyan
Push-Location $root
try{
 $previous=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $exit=$LASTEXITCODE
 }finally{$ErrorActionPreference=$previous}
 if($exit -ne 0){throw ('Error Wrangler '+$exit)}
}finally{Pop-Location}
Write-Host '=== COMPROBAR SESION V5 SIN CONSUMIR KV ===' -ForegroundColor Cyan
$ok=$false
for($i=1;$i -le 10;$i++){
 try{
  $h=Invoke-RestMethod -Uri ($target+'health?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  $page=Invoke-WebRequest -UseBasicParsing -Uri ($target+'?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($h.ok -and $h.production_connected -eq $true -and
     $h.session_auth -ceq 'signed_cookie_v1' -and
     $page.StatusCode -eq 200 -and $page.Content.Contains('function hideOptimistically(item)')){
   $ok=$true;break
  }
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$ok){throw 'Despliegue completado, pero no se pudo verificar la nueva sesion y la retirada real. No se modifica produccion.'}
Write-Host 'V5 VALIDADA: Worker REAL + sesion segura + retirada inmediata de Listas.' -ForegroundColor Green
Write-Host 'No se han creado recursos, procesos Chrome ni tareas.'
Write-Host ('Abre TTActualidad en iPhone: '+$target)
Write-Host 'Una sola vinculación despues de actualizar; cookie segura de 30 dias.'
