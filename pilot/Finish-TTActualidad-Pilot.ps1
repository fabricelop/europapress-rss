#requires -Version 5.1
# Finish the ALREADY DEPLOYED TTActualidad pilot. Never modify production.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$name = 'ttactualidad-decisions-pilot'
$kvTitle = 'ttactualidad-decisions-pilot-pilot-decisions'
$kvId = '231e2ba56ef443f9be857e23a5881847'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$keyFile = Join-Path $root 'pilot-token.dpapi.txt'
function Step([string]$msg) { Write-Host ''; Write-Host ('=== ' + $msg + ' ===') -ForegroundColor Cyan }
function Wrangler([string[]]$argsList) {
  $before = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $script:wrangler @argsList
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $before }
  if ($code -ne 0) { throw ('Wrangler error ' + $code + ' en ' + ($argsList -join ' ')) }
}
Step 'REUTILIZAR WORKER Y KV YA EXISTENTES'
if (!(Test-Path -LiteralPath $config)) { throw 'Falta configuracion local del Worker de prueba' }
if (!(Test-Path -LiteralPath $wrangler)) { throw 'No se encuentra Wrangler local. No se tocara Cloudflare.' }
if (!(Test-Path -LiteralPath (Join-Path $root 'ttactualidad-worker.js'))) { throw 'Falta el Worker piloto local' }
if (!(Test-Path -LiteralPath (Join-Path $root 'site\index.html'))) { throw 'Falta la web del piloto local' }
$health = Invoke-RestMethod -Uri ($url + '/health') -TimeoutSec 25
if (!$health.ok -or $health.kind -ne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false) {
  throw 'La URL existente no identifica al Worker piloto aislado'
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
if ($cfg.name -cne $name -or $cfg.main -cne './ttactualidad-worker.js') {
  throw 'La configuracion no corresponde al Worker piloto; abortado'
}
$bindings = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if ($bindings.Count -ne 1 -or @($cfg.kv_namespaces).Count -ne 1) {
  throw 'La configuracion de KV no es exclusiva o es ambigua'
}
$previous = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $output = & $wrangler kv namespace list --config $config 2>$null
  $exitCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $previous }
if ($exitCode -ne 0) { throw 'No se pudo consultar el KV de Cloudflare; no se cambiara nada' }
try { $namespaces = @($output | Out-String | ConvertFrom-Json) }
catch { throw 'La lista de KV no se pudo interpretar de manera segura' }
$found = @($namespaces | Where-Object { $_.title -ceq $kvTitle -and $_.id -ceq $kvId })
if ($found.Count -ne 1) { throw 'No coincide el ID y nombre del KV ya creado; abortado sin cambios' }
$existingId = [string]$bindings[0].id
if ($existingId -and $existingId -cne $kvId) { throw 'El archivo local apunta a un KV diferente; abortado' }
if (!$existingId) {
  $bindings[0] | Add-Member -NotePropertyName 'id' -NotePropertyValue $kvId -Force
  [IO.File]::WriteAllText($config, ($cfg | ConvertTo-Json -Depth 12), ([Text.UTF8Encoding]::new($false)))
  Write-Host 'KV ya existente asociado a la configuracion local; no se crea otro.'
} else { Write-Host 'La configuracion ya tiene el KV correcto.' }

Push-Location $root
try {
  Step 'CONFIRMAR BINDING DEL WORKER PILOTO'
  Wrangler -argsList @('deploy','--config',$config)
  Step 'CREAR O REUTILIZAR CLAVE PRIVADA'
  if (Test-Path -LiteralPath $keyFile) {
    $cipher = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
    $secure = ConvertTo-SecureString -String $cipher
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
  } else {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $secure = ConvertTo-SecureString -String $token -AsPlainText -Force
    $cipher = ConvertFrom-SecureString -SecureString $secure
    [IO.File]::WriteAllText($keyFile, $cipher, ([Text.UTF8Encoding]::new($false)))
  }
  if (!$token -or $token.Length -lt 32) { throw 'La clave del piloto es invalida' }
  $secretFile=Join-Path $root ('pilot-secret-'+[guid]::NewGuid().ToString('N')+'.json')
  try {
    [IO.File]::WriteAllText($secretFile,(@{PILOT_TOKEN=$token}|ConvertTo-Json -Compress),([Text.UTF8Encoding]::new($false)))
    $previous=$ErrorActionPreference
    try {
      $ErrorActionPreference='Continue'
      & $wrangler secret bulk $secretFile --config $config
      $secretCode=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previous }
    if($secretCode -ne 0){throw 'No se pudo configurar la clave privada de Cloudflare'}
  } finally {
    Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue
  }

  Step 'PRUEBA REAL: ENVIO Y CONSULTA SOLO EN KV PILOTO'
  $auth = @{ Authorization = ('Bearer ' + $token) }
  $check = Invoke-RestMethod -Uri ($url + '/api/decisions') -Headers $auth -TimeoutSec 30
  if (!$check.ok -or $check.mode -ne 'pilot_only') { throw 'La lectura privada del piloto ha fallado' }
  $eid = 'pilot-install-' + [guid]::NewGuid().ToString('N')
  $requestId = [guid]::NewGuid().ToString()
  $payload = @{project='ttittulares';event_id=$eid;decision='prepare';request_id=$requestId} | ConvertTo-Json
  $receipt = Invoke-RestMethod -Uri ($url + '/api/decision') -Headers $auth -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 30
  if (!$receipt.ok -or !$receipt.stored -or $receipt.production_connected -ne $false) { throw 'El Worker no confirmo el guardado aislado' }
  $readback = Invoke-RestMethod -Uri ($url + '/api/decisions') -Headers $auth -TimeoutSec 30
  if (@($readback.items | Where-Object { $_.event_id -eq $eid -and $_.decision -eq 'prepare' }).Count -ne 1) {
    throw 'El KV piloto no devolvio la decision de prueba'
  }
  try {
    Set-Clipboard -Value $token -ErrorAction Stop
    Write-Host 'Clave privada copiada al portapapeles; no se muestra ni se envia por el chat.'
  } catch { Write-Warning 'No se pudo copiar la clave. Sigue cifrada en tu PC.' }
  Write-Host 'PRUEBA OK: Worker, KV, escritura, lectura y autenticacion.' -ForegroundColor Green
  Write-Host ('Abre en el iPhone: ' + $url + '/')
  Write-Host 'En Configurar Worker, acepta esa URL y pega la clave del portapapeles.'
  Write-Host 'Las ordenes siguen SIN conectarse a produccion ni a Telegram.'
} finally { Pop-Location }
