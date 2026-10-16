#requires -Version 5.1
# Update only TTActualidad pilot HTML; do not touch production or other projects.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$site=Join-Path $root 'site\index.html'
$worker=Join-Path $root 'ttactualidad-worker.js'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$pin='926538ff41bcdfd04ba58a815e1e3405cb3a00b2'
$url='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/docs/index.html'
$target='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V7: TENDENCIAS SIN DEPENDER DE TELEGRAM ===' -ForegroundColor Cyan
foreach($f in @($config,$site,$worker,$wrangler)){if(!(Test-Path -LiteralPath $f)){throw ('Falta fichero del piloto: '+$f)}}
$cfg=Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'No coincide el Worker piloto; cancelado.'
}
$health=Invoke-RestMethod -Uri ($target+'health') -TimeoutSec 25
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $true -or $health.session_auth -cne 'signed_cookie_v1'){
 throw 'No se confirma la version segura V5 REAL; no se despliega.'
}
$oldWorker=[IO.File]::ReadAllText($worker,[Text.Encoding]::UTF8)
if(!$oldWorker.Contains("route==='/api/session'")){throw 'Worker local no contiene la sesion V5; cancelado.'}
$tmp=Join-Path $root 'v7-ui-download.html'
Invoke-WebRequest -UseBasicParsing -Uri ($url+'?v='+$pin) -OutFile $tmp -TimeoutSec 60
$html=[IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
if(!$html.Contains('https://t.me/TTImages_bot') -or !$html.Contains('grid-template-columns:repeat(2,minmax(0,1fr))') -or
 !$html.Contains('function hideOptimistically(item)') -or !$html.Contains('async function ensurePilotConnection()') -or
 $html.Contains('function pilotSwipes(') -or $html.Contains('touchstart') -or $html.Contains('touchend') -or !$html.Contains('A Telegram message is no longer a precondition') -or !$html.Contains("'trends/telegram-manual-explained.json','manual'")){
 throw 'Los marcadores de V7 no coinciden. No se despliega.'
}
$first=$html.IndexOf('<script>')
$last=$html.IndexOf('</script>',$first)
if($first -lt 0 -or $last -le $first){throw 'No aparece el script web V7'}
$check=Join-Path $root 'v7-ui-check.js'
[IO.File]::WriteAllText($check,$html.Substring($first+8,$last-$first-8),([Text.UTF8Encoding]::new($false)))
try{
 & node.exe --check $check
 if($LASTEXITCODE -ne 0){throw 'Script V7 no valido'}
}finally{Remove-Item $check -Force -ErrorAction SilentlyContinue}
Copy-Item -LiteralPath $site -Destination (Join-Path $root 'index.before-v7.bak') -Force
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Push-Location $root
try{
 $oldError=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $code=$LASTEXITCODE
 }finally{$ErrorActionPreference=$oldError}
 if($code -ne 0){throw ('Wrangler ha fallado: '+$code)}
}finally{Pop-Location}
$ok=$false
for($i=1;$i -le 10;$i++){
 try{
  $h=Invoke-RestMethod -Uri ($target+'health?t='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  $r=Invoke-WebRequest -UseBasicParsing -Uri ($target+'?t='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($h.ok -and $h.production_connected -eq $true -and $h.session_auth -ceq 'signed_cookie_v1' -and
   $r.StatusCode -eq 200 -and !$r.Content.Contains('function pilotSwipes(') -and
   $r.Content.Contains('function hideOptimistically(item)')){$ok=$true;break}
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 3}
}
if(!$ok){throw 'Desplegado pero no se ha podido verificar V7 en remoto.'}
Write-Host 'V7 OK: TTendencias Listas desde editorial, sin exigir Telegram; borrado real, sesiones y 8 botones intactos.' -ForegroundColor Green
Write-Host 'Nada cambiado: TTiTTulares, TTendencias, Telegram, SeLoRecordamos, TTImages, Chrome.'
Write-Host ('iPhone: '+$target)
