#requires -Version 5.1
# Offline QR pairing for TTActualidad iPhone pilot. No production modifications.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$keyFile=Join-Path $root 'pilot-token.dpapi.txt'
$worker=Join-Path $root 'ttactualidad-worker.js'
$site=Join-Path $root 'site\index.html'
$url='https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$source='https://raw.githubusercontent.com/fabricelop/europapress-rss/pilot/ttactualidad-direct-decisions-20261015/docs/index.html'
function Step([string]$title){Write-Host '';Write-Host ('=== '+$title+' ===') -ForegroundColor Cyan}
Step 'COMPROBAR WORKER Y KV DE PRUEBA'
foreach($path in @($config,$wrangler,$keyFile,$worker,$site)){
 if(!(Test-Path -LiteralPath $path)){throw ('Archivo piloto no encontrado: '+$path)}
}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $cfg.main -cne './ttactualidad-worker.js' -or @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'La configuracion no coincide con el piloto esperado. Cancelado.'
}
$health=Invoke-RestMethod -Uri ($url+'health') -TimeoutSec 30
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false){
 throw 'El Worker no confirma aislamiento del piloto. Cancelado.'
}
Step 'PREPARAR LA WEB DE PRUEBAS PARA EL IPHONE'
$tmp=Join-Path $root 'pilot-pair-web-check.html'
Invoke-WebRequest -UseBasicParsing -Uri $source -OutFile $tmp -TimeoutSec 45
$html=[IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if(!$html.Contains('async function pilotPairFromUrl()') -or !$html.Contains('ttactualidad-pair') -or !$html.Contains('pilotSend(item,decision)')){
 throw 'Version inesperada del piloto, no se despliega.'
}
$siteBackup=Join-Path $root 'index.before-iphone-pair.bak'
if(!(Test-Path -LiteralPath $siteBackup)){Copy-Item -LiteralPath $site -Destination $siteBackup}
[IO.File]::WriteAllText($site,$html,([Text.UTF8Encoding]::new($false)))
Push-Location $root
try{
 $before=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $deployCode=$LASTEXITCODE
 } finally { $ErrorActionPreference=$before }
 if($deployCode -ne 0){throw ('El deploy exclusivo del piloto fallo (codigo '+$deployCode+')')}
}finally{Pop-Location}
$ready=$false
for($i=1;$i -le 10;$i++){
 try{
  $resp=Invoke-WebRequest -UseBasicParsing -Uri ($url+'?pair_check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
  if($resp.StatusCode -eq 200 -and $resp.Content.Contains('pilotPairFromUrl')){$ready=$true;break}
 }catch{}
 if($i -lt 10){Start-Sleep -Seconds 2}
}
if(!$ready){throw 'La web del piloto aun no refleja el emparejamiento. No se generara el QR.'}
Step 'GENERAR QR LOCAL; NUNCA ENVIAR CLAVE A SERVIDORES EXTERNOS'
$nodeModule=Join-Path $root 'node_modules\qrcode'
if(!(Test-Path -LiteralPath $nodeModule)){
 $before=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & npm.cmd --prefix $root install --no-save --ignore-scripts --no-audit --no-fund 'qrcode@1.5.4'
  $npmCode=$LASTEXITCODE
 }finally{$ErrorActionPreference=$before}
 if($npmCode -ne 0){throw ('No se pudo instalar QR local (codigo '+$npmCode+')')}
}
$cipher=(Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
$secure=ConvertTo-SecureString -String $cipher
$pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
if($token.Length -lt 32 -or $token -cnotmatch '^[A-Za-z0-9_-]{32,100}$'){throw 'La clave local tiene un formato inesperado'}
$png=Join-Path $env:TEMP ('ttactualidad-pilot-iphone-'+[guid]::NewGuid().ToString('N')+'.png')
$generator=Join-Path $root 'pilot-qr-local.cjs'
$js=@'
const QR=require("qrcode");
const url="https://ttactualidad-decisions-pilot.fabricelop.workers.dev/#ttactualidad-pair="+encodeURIComponent(process.env.TT_PILOT_PAIR_TOKEN);
QR.toFile(process.env.TT_PILOT_PAIR_PATH,url,{width:600,margin:3,errorCorrectionLevel:"M"}).then(()=>console.log("QR local listo.")).catch(err=>{console.error("No se pudo generar QR local.");process.exitCode=1;});
'@
[IO.File]::WriteAllText($generator,$js,([Text.UTF8Encoding]::new($false)))
$env:TT_PILOT_PAIR_TOKEN=$token
$env:TT_PILOT_PAIR_PATH=$png
try {
 Push-Location $root
 try{
  & node.exe $generator
  $qrCode=$LASTEXITCODE
 }finally{Pop-Location}
 if($qrCode -ne 0 -or !(Test-Path -LiteralPath $png)){throw 'No se pudo generar el QR de prueba.'}
 Write-Host 'Escanea el codigo QR desde la camara del iPhone y abre el enlace.' -ForegroundColor Green
 Write-Host 'TTActualidad verificara tu clave y mostrara: iPhone vinculado al piloto.'
 Write-Host 'El codigo QR contiene una clave privada. No hagas capturas ni lo compartas.'
 Start-Process -FilePath $png
 Read-Host 'Cuando hayas abierto TTActualidad en el iPhone, pulsa ENTER aqui para borrar el QR'
}finally{
 Remove-Item Env:TT_PILOT_PAIR_TOKEN -ErrorAction SilentlyContinue
 Remove-Item Env:TT_PILOT_PAIR_PATH -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $generator,$png -Force -ErrorAction SilentlyContinue
}
Write-Host ('Piloto abierto mediante: '+$url)
Write-Host 'La clave no se guarda en la web; si cierras o recargas, vuelve a escanear el QR.'
Write-Host 'Produccion TTiTTulares, TTendencias y Telegram: SIN CAMBIOS.'
