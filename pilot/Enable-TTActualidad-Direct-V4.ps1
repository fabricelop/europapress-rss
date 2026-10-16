#requires -Version 5.1
# One-time V4 setup. Existing isolated Worker only; no new Cloudflare resources.
param([switch]$OnlyUI)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$worker=Join-Path $root 'ttactualidad-worker.js'
$site=Join-Path $root 'site\index.html'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$version='80b7232d2d38292fb415038e5280629adc250c91'
$base='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$version+'/'
$target='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V4: 4x2 BOTONES Y RETIRADA DIRECTA ==='
foreach($f in @($config,$worker,$site,$wrangler)){
 if(!(Test-Path -LiteralPath $f)){throw ('Falta archivo local del piloto: '+$f)}
}
$cfg=Get-Content $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'El entorno no corresponde al Worker piloto aislado. Cancelado.'
}
$health=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 20
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot'){
 throw 'El Worker no responde como piloto. Cancelado.'
}
foreach($f in @('pilot/apply-ttactualidad-action.py','.github/workflows/ttactualidad-direct-actions.yml')){
 $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/'+$f
 $resp=Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30
 if($resp.StatusCode -ne 200 -or $resp.Content.Length -lt 400){throw ('Receptor GitHub no instalado: '+$f)}
}
$downloadW=Join-Path $root 'v4-worker-check.mjs'
$downloadH=Join-Path $root 'v4-web-check.html'
Invoke-WebRequest -UseBasicParsing -Uri ($base+'pilot/ttactualidad-worker.js?sha='+$version) -OutFile $downloadW -TimeoutSec 60
Invoke-WebRequest -UseBasicParsing -Uri ($base+'docs/index.html?sha='+$version) -OutFile $downloadH -TimeoutSec 60
$code=[IO.File]::ReadAllText($downloadW,[Text.Encoding]::UTF8)
$html=[IO.File]::ReadAllText($downloadH,[Text.Encoding]::UTF8)
if(!$html.Contains('https://t.me/TTImages_bot') -or !$html.Contains('grid-template-columns:repeat(2,minmax(0,1fr))') -or !$html.Contains("btn('Copiar GAG Completo'") -or !$html.Contains('function refreshPilotConnection()') -or !$code.Contains("route==='/api/auth'") -or !$code.Contains('revision_required')){
 throw 'Archivos V4 descargados no coinciden. No se despliega.'
}
& node.exe --check $downloadW
if($LASTEXITCODE -ne 0){throw 'Worker JS invalido'}
$first=$html.IndexOf('<script>');$last=$html.IndexOf('</script>',$first)
if($first -lt 0 -or $last -le $first){throw 'Script web no encontrado'}
$jsfile=Join-Path $root 'v4-web-check.js'
[IO.File]::WriteAllText($jsfile,$html.Substring($first+8,$last-$first-8),([Text.UTF8Encoding]::new($false)))
try{& node.exe --check $jsfile;if($LASTEXITCODE -ne 0){throw 'Web JS invalido'}}
finally{Remove-Item $jsfile -Force -ErrorAction SilentlyContinue}
Copy-Item $worker (Join-Path $root 'worker.before-v4.bak') -Force
Copy-Item $site (Join-Path $root 'index.before-v4.bak') -Force
[IO.File]::WriteAllText($worker,$code,([Text.UTF8Encoding]::new($false)))
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
Remove-Item $downloadW,$downloadH -Force -ErrorAction SilentlyContinue
function ExecuteWrangler([scriptblock]$Operation){
 Push-Location $root
 try{
  $previous=$ErrorActionPreference
  try{$ErrorActionPreference='Continue'; & $Operation; $exitCode=$LASTEXITCODE}
  finally{$ErrorActionPreference=$previous}
  if($exitCode -ne 0){throw ('Wrangler termino con codigo '+$exitCode)}
 }finally{Pop-Location}
}
Write-Host '=== DESPLEGAR SOLO WEB + WORKER EXISTENTES ==='
ExecuteWrangler { & $wrangler deploy --config $config }
$visible=$false
for($i=1;$i -le 10;$i++){
 try{
  $response=Invoke-WebRequest -UseBasicParsing -Uri ($target+'?v4='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($response.StatusCode -eq 200 -and $response.Content.Contains('https://t.me/TTImages_bot') -and $response.Content.Contains("btn('Copiar GAG Completo'")){$visible=$true;break}
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$visible){throw 'Interfaz V4 desplegada pero aun no visible. No se activaran secretos.'}
Write-Host 'INTERFAZ V4 OK: botones 4x2 y TTImages directo.' -ForegroundColor Green
if($OnlyUI){
 Write-Host 'OnlyUI: no se ha cambiado la activacion de las acciones.'
 Write-Host ('iPhone: '+$target)
 return
}
Write-Host '=== ACTIVAR QUITAR DE LISTAS REAL ==='
Write-Host 'Crea un token GitHub fine-grained si todavia no tienes uno:'
Write-Host 'https://github.com/settings/personal-access-tokens/new'
Write-Host 'Repository access: Only select repositories -> fabricelop/europapress-rss'
Write-Host 'Repository permissions: Contents -> Read and write'
Write-Host 'NO envies nunca el token a ChatGPT. Pegalo solo en el cuadro oculto de PowerShell.'
$secure=Read-Host 'Token GitHub para conexion directa (entrada oculta)' -AsSecureString
if($null -eq $secure){throw 'Sin token. V4 visual instalada, retirada REAL no activada.'}
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
if([string]::IsNullOrWhiteSpace($token) -or $token.Length -lt 20){throw 'Token no valido. Retirada REAL no activada.'}
$headers=@{Authorization=('Bearer '+$token);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='TTActualidad-Setup'}
$body='{"event_type":"ttactualidad_auth_check_v1","client_payload":{"purpose":"preflight_only"}}'
try{
 $res=Invoke-WebRequest -UseBasicParsing -Uri 'https://api.github.com/repos/fabricelop/europapress-rss/dispatches' -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30
 if($res.StatusCode -ne 204){throw 'GitHub no devolvio HTTP 204'}
}catch{
 $token=$null
 throw 'La credencial no permite enviar eventos a ese repositorio. Solo interfaz V4 instalada. Corrige permisos Contents read/write.'
}
Write-Host 'Validacion GitHub OK (evento sin workflow: ninguna noticia modificada).' -ForegroundColor Green
try{
 $tokenCopy=$token
 ExecuteWrangler { Write-Output $tokenCopy | & $wrangler secret put GH_DISPATCH_TOKEN --config $config }
 $tokenCopy=$null
 $token=$null
 ExecuteWrangler { Write-Output 'github_dispatch' | & $wrangler secret put ACTION_MODE --config $config }
}finally{$tokenCopy=$null;$token=$null;$secure=$null}
$enabled=$false
for($i=1;$i -le 10;$i++){
 try{
  $h=Invoke-RestMethod -Uri ($target+'health?mode='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($h.ok -and $h.production_connected -eq $true -and $h.architecture -ceq 'on_demand_no_polling'){$enabled=$true;break}
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$enabled){throw 'No se ha podido verificar modo REAL. No afirmes que las retiradas funcionen.'}
Write-Host 'ACTIVO: Quitar de Listas envia a GitHub sin Telegram ni Chrome.' -ForegroundColor Green
Write-Host 'Desestimar y Elaborar NO se han modificado. Las retiradas se confirman en GitHub.'
Write-Host ('iPhone: '+$target)
