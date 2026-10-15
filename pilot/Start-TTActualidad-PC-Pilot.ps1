#requires -Version 5.1
# Read-only Cloudflare/GitHub PC simulator. NO production actions or scheduled tasks.
param(
  [switch]$Watch,
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$keyFile=Join-Path $root 'pilot-token.dpapi.txt'
$nodeFile=Join-Path $root 'ttactualidad-pc-dryrun.mjs'
$source='https://raw.githubusercontent.com/fabricelop/europapress-rss/pilot/ttactualidad-direct-decisions-20261015/pilot/ttactualidad-pc-dryrun.mjs'
if(!(Get-Command node.exe -ErrorAction SilentlyContinue)){throw 'Node.js 20+ no esta disponible'}
if(!(Test-Path -LiteralPath $config)){throw 'No existe configuracion local del piloto'}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($cfg.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $kv.Count -ne 1 -or
   [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'Configuracion ajena al piloto; cancelado'
}
Invoke-WebRequest -UseBasicParsing -Uri $source -OutFile $nodeFile -TimeoutSec 45
$js=[IO.File]::ReadAllText($nodeFile,[Text.Encoding]::UTF8)
if(!$js.Contains('SIN ACCIONES REALES') -or !$js.Contains('DRYRUN') -or !$js.Contains('function reconcile(')){
 throw 'Version inesperada del simulador: cancelado'
}
& node.exe --check $nodeFile
if($LASTEXITCODE -ne 0){throw 'JavaScript del simulador no valido'}
Write-Host '=== AUTOTEST DEL SIMULADOR ===' -ForegroundColor Cyan
& node.exe $nodeFile --self-test
if($LASTEXITCODE -ne 0){throw 'El autotest fallo. No se consultara Cloudflare'}
if($SelfTest){return}
if(!(Test-Path -LiteralPath $keyFile)){throw 'No se encuentra clave cifrada del piloto'}
$cipher=(Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
$secret=ConvertTo-SecureString -String $cipher
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
if($token.Length -lt 32 -or $token -cnotmatch '^[A-Za-z0-9_-]{32,100}$'){
 throw 'Clave piloto no valida'
}
$env:TT_PILOT_TOKEN=$token
try{
 Write-Host '=== CONSUMIDOR PC: SOLO SIMULACION ===' -ForegroundColor Cyan
 if($Watch){
  Write-Host 'Lectura periodica cada 60 segundos. Pulsa Ctrl+C para detener.'
  & node.exe $nodeFile --watch
 }else{
  & node.exe $nodeFile --once
 }
 if($LASTEXITCODE -ne 0){throw ('Simulador finalizo con codigo '+$LASTEXITCODE)}
}finally{
 Remove-Item Env:TT_PILOT_TOKEN -ErrorAction SilentlyContinue
}
