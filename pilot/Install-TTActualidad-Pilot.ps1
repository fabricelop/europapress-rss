#requires -Version 5.1
# TTActualidad: installer for an ISOLATED Cloudflare pilot. Does not alter production.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$name='ttactualidad-decisions-pilot'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$site=Join-Path $root 'site'
$config=Join-Path $root 'wrangler.jsonc'
$keyFile=Join-Path $root 'pilot-token.dpapi.txt'
$source='https://raw.githubusercontent.com/fabricelop/europapress-rss/pilot/ttactualidad-direct-decisions-20261015'
function Step([string]$s){Write-Host '';Write-Host ('=== '+$s+' ===') -ForegroundColor Cyan}
function Download([string]$file,[string]$destination){
  Invoke-WebRequest -Uri ($source+'/'+$file) -OutFile $destination -UseBasicParsing -TimeoutSec 60
  if(!(Test-Path $destination) -or (Get-Item $destination).Length -lt 30){throw ('Failed to download '+$file)}
}
# Windows PowerShell 5.1 can turn harmless native stderr warnings into
# terminating NativeCommandError when ErrorActionPreference is Stop.
# Native commands are checked strictly via their actual process exit codes.
function Run-Wrangler([string[]]$parameters){
  $previous=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    & $script:wrangler @parameters
    $exitCode=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$previous
  }
  if($exitCode -ne 0){throw ('Wrangler exited '+$exitCode+': '+($parameters -join ' '))}
}
Step 'COMPROBACIONES: SOLO PILOTO'
if(!(Get-Command node.exe -ErrorAction SilentlyContinue)){throw 'Node.js 20+ no encontrado'}
if(!(Get-Command npm.cmd -ErrorAction SilentlyContinue)){throw 'npm no encontrado'}
$nodeVersion=(& node.exe -p 'process.versions.node').Trim()
if([int]$nodeVersion.Split('.')[0] -lt 20){throw ('Node.js '+$nodeVersion+' es demasiado antiguo')}
Write-Host ('Node.js '+$nodeVersion)
New-Item -ItemType Directory -Force -Path $site | Out-Null
Step 'DESCARGA DE CODIGO INDEPENDIENTE'
Download 'pilot/ttactualidad-worker.js' (Join-Path $root 'ttactualidad-worker.js')
Download 'docs/index.html' (Join-Path $site 'index.html')
Download 'docs/icon.svg' (Join-Path $site 'icon.svg')
Download 'docs/manifest.webmanifest' (Join-Path $site 'manifest.webmanifest')
$html=[IO.File]::ReadAllText((Join-Path $site 'index.html'),[Text.Encoding]::UTF8)
$worker=[IO.File]::ReadAllText((Join-Path $root 'ttactualidad-worker.js'),[Text.Encoding]::UTF8)
if(!$html.Contains('const directPilot=') -or !$worker.Contains('isolated-ttactualidad-pilot')){throw 'Los marcadores de codigo piloto no coinciden'}
$parseFile=Join-Path $root 'pilot-worker-parsecheck.mjs'
Copy-Item -LiteralPath (Join-Path $root 'ttactualidad-worker.js') -Destination $parseFile -Force
try{
  & node.exe --check $parseFile
  if($LASTEXITCODE -ne 0){throw 'El Worker tiene un error de sintaxis'}
}finally{Remove-Item -LiteralPath $parseFile -ErrorAction SilentlyContinue}

Step 'WRANGLER LOCAL AL PILOTO'
$script:wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
if(!(Test-Path $script:wrangler)){
  $previous=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    & npm.cmd --prefix $root install --no-audit --no-fund --save-exact 'wrangler@latest'
    $npmExit=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$previous
  }
  if($npmExit -ne 0){throw ('npm fallo con codigo '+$npmExit)}
}
if(!(Test-Path $script:wrangler)){throw 'No se encontro wrangler.cmd'}

# Wrangler auto-provisions a dedicated KV namespace on the first deploy.
# On reruns its generated namespace ID is kept in this local config.
if(Test-Path $config){
  $old=Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
  if($old.name -ne $name){throw 'Existe una configuracion ajena en el directorio piloto. Cancelado.'}
}else{
  $cfg=@{
    name=$name
    main='./ttactualidad-worker.js'
    compatibility_date='2026-10-15'
    workers_dev=$true
    assets=@{directory='./site';binding='ASSETS';run_worker_first=@('/health','/api/*');not_found_handling='404-page'}
    kv_namespaces=@(@{binding='PILOT_DECISIONS'})
  }
  [IO.File]::WriteAllText($config,($cfg|ConvertTo-Json -Depth 8),([Text.UTF8Encoding]::new($false)))
}
Push-Location $root
try{
  Step 'AUTORIZACION DE CLOUDFLARE'
  Write-Host 'Si es necesario, Wrangler abrira el navegador para autorizar el acceso.'
  $previous=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    & $script:wrangler whoami --config $config
    $whoamiExit=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$previous
  }
  if($whoamiExit -ne 0){
    Run-Wrangler -parameters @('login','--config',$config)
    Run-Wrangler -parameters @('whoami','--config',$config)
  }
  Step 'DESPLIEGUE DEL WORKER Y KV EXCLUSIVOS'
  Write-Host ('Solo se desplegara '+$name)
  Run-Wrangler -parameters @('deploy','--config',$config)
  $saved=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
  $kv=@($saved.kv_namespaces|Where-Object {$_.binding -eq 'PILOT_DECISIONS'})
  if($kv.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$kv[0].id)){
    throw 'No se ha confirmado el KV exclusivo tras el despliegue. Se detiene antes de crear credenciales.'
  }
  Step 'CLAVE DE AUTENTICACION DEL PILOTO'
  if(Test-Path $keyFile){
    $encrypted=(Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
    $secure=ConvertTo-SecureString $encrypted
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}
    finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
  }else{
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    $token=[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $secure=ConvertTo-SecureString $token -AsPlainText -Force
    $encrypted=ConvertFrom-SecureString $secure
    [IO.File]::WriteAllText($keyFile,$encrypted,([Text.UTF8Encoding]::new($false)))
  }
  if(!$token -or $token.Length -lt 32){throw 'Token piloto invalido'}
  $env:TT_ACTUALIDAD_PILOT_TOKEN=$token
  try{
    $previous=$ErrorActionPreference
    try {
      $ErrorActionPreference='Continue'
      & node.exe -e 'process.stdout.write(process.env.TT_ACTUALIDAD_PILOT_TOKEN)' |
        & $script:wrangler secret put PILOT_TOKEN --config $config
      $secretExit=$LASTEXITCODE
    } finally {
      $ErrorActionPreference=$previous
    }
    if($secretExit -ne 0){throw ('No se ha configurado el secreto PILOT_TOKEN (codigo '+$secretExit+')')}
  }finally{Remove-Item Env:TT_ACTUALIDAD_PILOT_TOKEN -ErrorAction SilentlyContinue}

  Step 'PRUEBA DE SALUD, AISLAMIENTO Y AUTENTICACION'
  $url='https://ttactualidad-decisions-pilot.fabricelop.workers.dev'
  try{
    $health=Invoke-RestMethod -Uri ($url+'/health') -TimeoutSec 30
    if(!$health.ok -or $health.production_connected -ne $false){throw 'Health no confirma aislamiento'}
    $response=Invoke-RestMethod -Uri ($url+'/api/decisions') -Headers @{Authorization=('Bearer '+$token)} -TimeoutSec 30
    if(!$response.ok -or $response.mode -ne 'pilot_only'){throw 'No se ha verificado KV'}
    Write-Host 'OK: Worker, KV y acceso privado, aislados de produccion.' -ForegroundColor Green
  }catch{
    Write-Warning ('Deploy realizado, pero verificaciones pendientes: '+$_.Exception.Message)
    Write-Warning 'Si Cloudflare asigna otro subdominio, usa la URL workers.dev que ha mostrado Wrangler.'
  }
  try{
    Set-Clipboard -Value $token -ErrorAction Stop
    Write-Host 'Clave privada copiada al portapapeles de Windows; NO se muestra en pantalla.'
  }catch{
    Write-Warning 'No se pudo copiar la clave. Esta guardada cifrada en el PC para recuperarla despues.'
  }
  Write-Host ('DIRECCION PILOTO: '+$url+'/') -ForegroundColor Green
  Write-Host 'En el piloto pulsa Configurar Worker, confirma la URL y pega la clave de tu portapapeles.'
  Write-Host 'NO compartas esa clave ni pegues logs que puedan incluirla.'
  Write-Host 'Produccion, Telegram y colas editoriales: SIN CAMBIOS.'
}finally{Pop-Location}
