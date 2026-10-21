#requires -Version 5.1
# TTActualidad V8.2.1 - ASCII-only installer compatible with Windows PowerShell 5.1.
# Update the existing static UI only. Preserve V8.1 Worker code, cookies, KV, secrets and tasks.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$source = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/14254f598d2a44cb46f9ef84e8872c2e3de4c2c6/pilot/ttactualidad-live/index.html'
$prefix = "x._status==='CRECIENDO'){command("
$suffix = "','prepare');command('Desestimar','discard')}"
Write-Host '=== TTActualidad V8.2.1: boton Creciendo ===' -ForegroundColor Cyan
foreach ($p in @($config,$site,$worker,$wrangler)) {
    if (!(Test-Path -LiteralPath $p)) { throw ('Archivo obligatorio ausente: ' + $p) }
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if ($cfg.name -cne 'ttactualidad-decisions-pilot' -or
    $cfg.main -cne './ttactualidad-worker.js' -or
    @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
    [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847') {
    throw 'Configuracion Wrangler no reconocida. Sin cambios.'
}
$health = Invoke-RestMethod -Uri ($url + 'health?pre=' + [guid]::NewGuid().ToString('N')) -TimeoutSec 25
if (!$health.ok -or $health.version -cne 'v8.1-kv-conflict-fix' -or
    $health.production_connected -ne $true -or $health.session_auth -cne 'signed_cookie_v1') {
    throw 'El Worker V8.1 no coincide con el esperado. Sin cambios.'
}
$tmp = Join-Path $root 'ttactualidad-v821-index-download.html'
try {
    Invoke-WebRequest -UseBasicParsing -Uri ($source + '?v=' + [guid]::NewGuid().ToString('N')) -OutFile $tmp -TimeoutSec 60
    $incoming = [IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$foundPrefix = $incoming.Contains($prefix)
$foundSuffix = $incoming.Contains($suffix)
$foundBrand = $incoming.Contains('TTImages')
$foundGag = $incoming.Contains('Copiar GAG Completo')
Write-Host ('UI descargada: caracteres=' + $incoming.Length + '; boton_inicio=' + $foundPrefix +
            '; boton_fin=' + $foundSuffix + '; TTImages=' + $foundBrand + '; GAG=' + $foundGag)
if ($incoming.Length -lt 45000 -or !$foundPrefix -or !$foundSuffix -or !$foundBrand -or !$foundGag) {
    throw 'UI descargada no coincide con el commit fijado. No se ha cambiado nada.'
}
$scriptTag = '<script>'
$scriptStart = $incoming.IndexOf($scriptTag)
if ($scriptStart -lt 0) { throw 'Falta script de la interfaz.' }
$scriptStart += $scriptTag.Length
$scriptEnd = $incoming.IndexOf('</script>', $scriptStart)
if ($scriptEnd -le $scriptStart) { throw 'Javascript de interfaz incompleto.' }
$check = Join-Path $root 'ttactualidad-v821-ui-check.js'
try {
    [IO.File]::WriteAllText($check,$incoming.Substring($scriptStart,$scriptEnd-$scriptStart),
                           ([Text.UTF8Encoding]::new($false)))
    & node.exe --check $check
    if ($LASTEXITCODE -ne 0) { throw 'Javascript invalido; no se ha cambiado nada.' }
} finally {
    Remove-Item -LiteralPath $check -Force -ErrorAction SilentlyContinue
}
# Avoid unnecessary deploys when the live site already contains this update.
try {
    $remote = (Invoke-WebRequest -UseBasicParsing -Uri ($url + '?before=' +
              [guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
    if ($remote.Contains($prefix) -and $remote.Contains($suffix)) {
        Write-Host 'El boton ya aparece en la interfaz remota. No hace falta desplegar.' -ForegroundColor Green
        exit 0
    }
} catch {
    Write-Host 'No ha podido verificarse la UI actual; se aplicara la version fija.'
}
$workerHash = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
$backup = Join-Path $root ('index.before-creciendo-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html.bak')
Copy-Item -LiteralPath $site -Destination $backup -ErrorAction Stop
[IO.File]::WriteAllText($site,$incoming,([Text.UTF8Encoding]::new($false)))
$deployCode = -1
try {
    Push-Location $root
    try {
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $wrangler deploy --config $config
            $deployCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($deployCode -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $site -Force
    }
}
if ($deployCode -ne 0) {
    throw ('Wrangler fallo (' + $deployCode + '); archivo local restaurado.')
}
if ((Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -cne $workerHash) {
    throw 'El archivo Worker local cambio durante el despliegue: revisar antes de continuar.'
}
$verified = $false
for ($i = 0; $i -lt 8; $i++) {
    try {
        $after = Invoke-RestMethod -Uri ($url + 'health?post=' + [guid]::NewGuid().ToString('N')) -TimeoutSec 20
        $page = (Invoke-WebRequest -UseBasicParsing -Uri ($url + '?post=' +
                 [guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
        if ($after.ok -and $after.version -ceq 'v8.1-kv-conflict-fix' -and
            $after.production_connected -eq $true -and
            $page.Contains($prefix) -and $page.Contains($suffix)) {
            $verified = $true
            break
        }
    } catch {
        Write-Host ('Comprobacion remota ' + ($i+1) + ': ' + $_.Exception.Message)
    }
    if ($i -lt 7) { Start-Sleep -Seconds 3 }
}
if (!$verified) {
    throw 'Despliegue lanzado pero no confirmado remotamente. No lo repitas sin diagnostico.'
}
Write-Host 'V8.2.1 CONFIRMADA: boton de Creciendo disponible en la web.' -ForegroundColor Green
Write-Host 'Worker V8.1, KV, sesion y umbral automatico intactos.'
Write-Host ('Copia local: ' + $backup)
Write-Host 'Recarga la web con Ctrl+F5.'
