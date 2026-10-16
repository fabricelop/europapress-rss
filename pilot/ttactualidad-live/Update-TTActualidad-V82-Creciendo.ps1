#requires -Version 5.1
# TTActualidad V8.2: update only static UI to enable manual selection of
# 3-source "Creciendo" news. Preserve Worker V8.1, session, KV and secrets.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$source = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/pilot/ttactualidad-live/index.html'
$marker = "x._status==='CRECIENDO'){command('Pasar a En Elaboración','prepare')"
Write-Host '=== TTActualidad V8.2: boton manual Creciendo ===' -ForegroundColor Cyan
foreach ($p in @($config,$site,$worker,$wrangler)) {
    if (!(Test-Path -LiteralPath $p)) {throw ('Archivo obligatorio ausente: '+$p)}
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if ($cfg.name -cne 'ttactualidad-decisions-pilot' -or
    $cfg.main -cne './ttactualidad-worker.js' -or
    @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
    [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847') {
    throw 'Configuracion Wrangler no reconocida. Sin cambios.'
}
$health = Invoke-RestMethod -Uri ($url+'health?pre='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
if (!$health.ok -or $health.version -cne 'v8.1-kv-conflict-fix' -or
    $health.production_connected -ne $true -or $health.session_auth -cne 'signed_cookie_v1') {
    throw 'La instancia V8.1 no coincide. Sin cambios.'
}
$tmp = Join-Path $root 'ttactualidad-v82-index-download.html'
Invoke-WebRequest -UseBasicParsing -Uri ($source+'?t='+[guid]::NewGuid().ToString('N')) -OutFile $tmp -TimeoutSec 60
$incoming = [IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
if ($incoming.Length -lt 45000 -or !$incoming.Contains($marker) -or
    !$incoming.Contains('TTImages') -or !$incoming.Contains('Copiar GAG Completo')) {
    throw 'Nueva UI inesperada o sin boton Creciendo. Sin cambios.'
}
$scriptStart = $incoming.IndexOf('<script>') + '<script>'.Length
$scriptEnd = $incoming.IndexOf('</script>',$scriptStart)
if ($scriptStart -lt '<script>'.Length -or $scriptEnd -le $scriptStart) {
    throw 'No se ha localizado el Javascript de la interfaz.'
}
$check = Join-Path $root 'ttactualidad-v82-ui-check.js'
try {
    [IO.File]::WriteAllText($check,$incoming.Substring($scriptStart,$scriptEnd-$scriptStart),
                           ([Text.UTF8Encoding]::new($false)))
    & node.exe --check $check
    if ($LASTEXITCODE -ne 0) {throw 'Javascript de la interfaz invalido'}
} finally {
    Remove-Item -LiteralPath $check -Force -ErrorAction SilentlyContinue
}
$current = [IO.File]::ReadAllText($site,[Text.Encoding]::UTF8)
if ($current.Contains($marker)) {
    Write-Host 'Boton Creciendo ya instalado localmente.' -ForegroundColor Green
    # Also verify the remote asset; local state alone is insufficient.
    try {
        $remote = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
        if ($remote.Contains($marker)) {
            Write-Host 'V8.2 ya publicada y verificada.' -ForegroundColor Green
            exit 0
        }
    } catch {}
}
$backup = Join-Path $root ('index.before-creciendo-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.html.bak')
Copy-Item -LiteralPath $site -Destination $backup -ErrorAction Stop
[IO.File]::WriteAllText($site,$incoming,([Text.UTF8Encoding]::new($false)))
$code = -1
try {
    Push-Location $root
    try {
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            & $wrangler deploy --config $config
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference=$saved
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($code -ne 0) {Copy-Item -LiteralPath $backup -Destination $site -Force}
}
if ($code -ne 0) {throw ('Wrangler devolvio '+$code+'. UI local restaurada.')}
$verified=$false
for ($i=0;$i -lt 8;$i++) {
    try {
        $after = Invoke-RestMethod -Uri ($url+'health?post='+[guid]::NewGuid().ToString('N')) -TimeoutSec 20
        $page = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?post='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
        if ($after.ok -and $after.version -ceq 'v8.1-kv-conflict-fix' -and
            $after.production_connected -eq $true -and $page.Contains($marker)) {
            $verified=$true
            break
        }
    } catch {}
    if ($i -lt 7) {Start-Sleep -Seconds 3}
}
if (!$verified) {throw 'Despliegue lanzado, pero NO se pudo confirmar boton remoto. Revisar antes de repetir.'}
Write-Host 'CONFIRMADO: Creciendo permite Pasar a En Elaboracion con 3 fuentes.' -ForegroundColor Green
Write-Host 'Worker V8.1, historial y tareas intactos.'
Write-Host ('Copia de respaldo: '+$backup)
Write-Host 'Actualiza el panel con Ctrl+F5.'
