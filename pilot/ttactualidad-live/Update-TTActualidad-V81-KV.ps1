#requires -Version 5.1
# TTActualidad V8.1: worker-only patch. All script literals are ASCII for PS5.1.
# Does not modify static UI, cookies, KV namespace, secrets, other apps or Windows tasks.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$pin = '4094b217db5a543f759e4709e93fb164138adfb3'
$source = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/pilot/ttactualidad-live/worker.js'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V8.1: corregir bloqueo already_decided ===' -ForegroundColor Cyan
foreach($f in @($config,$site,$worker,$wrangler)){
 if(!(Test-Path -LiteralPath $f)){throw ('Archivo local obligatorio ausente: '+$f)}
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or
 @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
 [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion de Worker no coincide. Sin cambios.'
}
$before = Invoke-RestMethod -Uri ($url+'health?before='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
if(!$before.ok -or $before.kind -cne 'ttactualidad-direct-live' -or
 $before.production_connected -ne $true -or $before.session_auth -cne 'signed_cookie_v1'){
 throw 'No se ha validado la instancia V8 y su sesion. Sin cambios.'
}
if($before.version -ceq 'v8.1-kv-conflict-fix'){
 Write-Host 'V8.1 ya instalada. Ningun cambio necesario.' -ForegroundColor Green
 exit 0
}
$temp = Join-Path $root 'v81-worker-download.js'
Invoke-WebRequest -UseBasicParsing -Uri ($source+'?v='+$pin) -OutFile $temp -TimeoutSec 60
$newSource = [IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
foreach($marker in @('v8.1-kv-conflict-fix',
 'if(!live&&existing.decision!==decision)',
 'existing.decision===decision&&existing.routed===true&&live&&sameRevision',
 "route==='/api/session'", 'crypto.subtle.verify')){
 if(!$newSource.Contains($marker)){throw ('Worker V8.1 invalido: '+$marker)}
}
$check = Join-Path $root 'v81-check.mjs'
try{
 [IO.File]::WriteAllText($check,$newSource,([Text.UTF8Encoding]::new($false)))
 & node.exe --check $check
 if($LASTEXITCODE -ne 0){throw 'Error de sintaxis Worker V8.1'}
}finally{Remove-Item -LiteralPath $check -Force -ErrorAction SilentlyContinue}
$backup = Join-Path $root ('worker.before-v81-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')
Copy-Item -LiteralPath $worker -Destination $backup -Force
[IO.File]::WriteAllText($worker,$newSource,([Text.UTF8Encoding]::new($false)))
$code=-1
try{
 Push-Location $root
 try{
  $savedPreference=$ErrorActionPreference
  try{$ErrorActionPreference='Continue'; & $wrangler deploy --config $config; $code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$savedPreference}
 }finally{Pop-Location}
}finally{
 if($code -ne 0){Copy-Item -LiteralPath $backup -Destination $worker -Force}
}
if($code -ne 0){throw ('Fallo Wrangler '+$code+'. Fichero local restaurado.')}
$verified=$false
for($i=0;$i -lt 10;$i++){
 try{
  $health = Invoke-RestMethod -Uri ($url+'health?after='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($health.ok -and $health.kind -ceq 'ttactualidad-direct-live' -and
   $health.version -ceq 'v8.1-kv-conflict-fix' -and
   $health.production_connected -eq $true -and $health.session_auth -ceq 'signed_cookie_v1'){
   $verified=$true;break
  }
 }catch{}
 if($i -lt 9){Start-Sleep -Seconds 3}
}
if(!$verified){throw 'Despliegue realizado, pero la version V8.1 no esta confirmada remotamente.'}
Write-Host 'V8.1 CONFIRMADA: se admiten nuevas decisiones reales sobre un KV antiguo.' -ForegroundColor Green
Write-Host 'Sesion iPhone, URL, Listas y UI conservadas.'
Write-Host ('Worker backup: '+$backup)
Write-Host 'Vuelve a Quitar de Listas la noticia de Arde Bogota en el iPhone.'
