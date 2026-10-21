#requires -Version 5.1
# TTActualidad V8.4 - growing cards remain visible once GitHub moves them.
# ASCII installer: static UI patch only; Worker/KV/sessions/queues untouched.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$config = Join-Path $root 'wrangler.jsonc'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
Write-Host '=== TTActualidad V8.4: Creciendo -> En elaboracion ===' -ForegroundColor Cyan

foreach ($p in @($site,$worker,$config,$wrangler)) {
    if (-not (Test-Path -LiteralPath $p)) { throw ('Archivo obligatorio ausente: '+$p) }
}

$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if ($cfg.name -cne 'ttactualidad-decisions-pilot' -or
    $cfg.main -cne './ttactualidad-worker.js' -or
    $kv.Count -ne 1 -or
    [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847') {
    throw 'Configuracion de Worker/KV no reconocida. No se ha cambiado nada.'
}
$health = Invoke-RestMethod -Uri ($url+'health') -TimeoutSec 20
if (-not $health.ok -or $health.version -cne 'v8.1-kv-conflict-fix' -or
    $health.production_connected -ne $true) {
    throw 'Worker en produccion distinto al esperado. No se ha cambiado nada.'
}

$current = [IO.File]::ReadAllText($site, [Text.Encoding]::UTF8)
$old = 'return pendingDeletes.has(removeKey(itemProject(item),String(item._id)));'
$marker = 'const op=pendingDeletes.get(removeKey(itemProject(item),String(item._id)));'
$new = @'
const op=pendingDeletes.get(removeKey(itemProject(item),String(item._id)));
 if(!op)return false;
 // PREPARE moves a card; hide the old source only, not PROCESSING or READY.
 if(op.decision==='prepare')return item._status==='CRECIENDO'||item._status==='PROBLEM\u00C1TICA';
 return true;
'@
if ($current.Contains($marker)) {
    Write-Host 'La correccion ya esta en la copia local; se comprobara el despliegue.'
    $patched = $current
} else {
    if (-not $current.Contains($old) -or
        $current.Split(@($old),[StringSplitOptions]::None).Count -ne 2) {
        throw 'No se reconoce la funcion original. Sin cambios.'
    }
    $patched = $current.Replace($old,$new)
}
foreach ($required in @('Pasar a En Elaboraci', 'TTImages', 'Quitar de Listas', 'Tremending')) {
    if (-not $patched.Contains($required)) {
        throw ('Falta una funcion esperada de la interfaz: '+$required)
    }
}
$start = $patched.IndexOf('<script>')
$finish = $patched.IndexOf('</script>',$start)
if ($start -lt 0 -or $finish -le $start) { throw 'No se encontro el script de interfaz.' }
$node = (Get-Command node.exe -ErrorAction Stop).Source
$check = Join-Path $root 'ttactualidad-v84-js-check.js'
try {
    [IO.File]::WriteAllText($check,$patched.Substring($start+8,$finish-$start-8),
        ([Text.UTF8Encoding]::new($false)))
    & $node --check $check
    if ($LASTEXITCODE -ne 0) { throw 'Javascript invalido: sin despliegue.' }
} finally {
    Remove-Item -LiteralPath $check -Force -ErrorAction SilentlyContinue
}
$workerHash = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
$backup = Join-Path $root ('index.before-v84-growing-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html.bak')
Copy-Item -LiteralPath $site -Destination $backup -ErrorAction Stop
[IO.File]::WriteAllText($site,$patched,([Text.UTF8Encoding]::new($false)))
Write-Host ('Copia de seguridad: '+$backup)

$code = -1
try {
    Push-Location $root
    try {
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $wrangler deploy --config $config
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
    } finally {
        Pop-Location
    }
} catch {
    Copy-Item -LiteralPath $backup -Destination $site -Force
    throw
}
if ($code -ne 0) {
    Copy-Item -LiteralPath $backup -Destination $site -Force
    throw ('Wrangler fallo con codigo '+$code+'. Archivo local restaurado; despliegue no confirmado.')
}
if ((Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -cne $workerHash) {
    throw 'ALERTA: Worker local modificado inesperadamente.'
}
$verified = $false
for ($i=0; $i -lt 8; $i++) {
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?verify-v84='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
        if ($html.Contains($marker) -and $html.Contains("if(op.decision==='prepare')")) {
            $verified = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 4
}
if (-not $verified) {
    throw 'Despliegue enviado, pero no se ha verificado la interfaz remota. No repetir sin diagnostico.'
}
Write-Host 'V8.4 VERIFICADA: el movimiento Creciendo -> En elaboracion queda visible.' -ForegroundColor Green
Write-Host 'Worker, KV, sesiones, colas y decisiones preservados.'
Write-Host 'Recarga la app con Ctrl+F5 (en iPhone, recarga la pagina).'
