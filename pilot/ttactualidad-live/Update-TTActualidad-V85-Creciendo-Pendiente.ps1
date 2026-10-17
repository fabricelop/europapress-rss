#requires -Version 5.1
# TTActualidad V8.5 - mostrar traslados Creciendo -> En elaboracion en espera de GitHub.
# Actualiza solo el HTML estatico. Conserva Worker, KV, claves y sesiones.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$config = Join-Path $root 'wrangler.jsonc'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$revision = '0113dfe37b99074a06b143912a2d1b934d139cb1'
$source = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$revision+'/pilot/ttactualidad-live/index.html'
Write-Host '=== TTActualidad V8.5: Creciendo -> En elaboracion visible ===' -ForegroundColor Cyan

foreach($file in @($site,$worker,$config,$wrangler)) {
    if(-not (Test-Path -LiteralPath $file)) { throw ('Falta el archivo: '+$file) }
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object {$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or
   $cfg.main -cne './ttactualidad-worker.js' -or
   $kv.Count -ne 1 -or
   [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847') {
    throw 'Worker/KV desconocidos: no se ha modificado nada.'
}
$health = Invoke-RestMethod -Uri ($url+'health') -TimeoutSec 20
if(-not $health.ok -or $health.version -cne 'v8.1-kv-conflict-fix' -or
   $health.production_connected -ne $true) {
    throw 'El Worker publicado no es el esperado: sin cambios.'
}

$temp = Join-Path $env:TEMP ('ttactualidad-v85-'+[guid]::NewGuid().ToString('N')+'.html')
$js = Join-Path $env:TEMP ('ttactualidad-v85-'+[guid]::NewGuid().ToString('N')+'.js')
try {
    Invoke-WebRequest -UseBasicParsing -Uri $source -OutFile $temp -TimeoutSec 45
    $html = [IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
    foreach($marker in @('PENDIENTE DE CONFIRMACI','readyConfirmed','Noticia elaborada: ya est',
                        'TTImages','Tremending','Pasar a En Elaboraci')) {
        if(-not $html.Contains($marker)) {throw ('Interfaz descargada sin marca esperada: '+$marker)}
    }
    $begin = $html.IndexOf('<script>')+8
    $end = $html.IndexOf('</script>',$begin)
    if($begin -lt 8 -or $end -lt $begin) {throw 'No se encuentra Javascript.'}
    [IO.File]::WriteAllText($js,$html.Substring($begin,$end-$begin),[Text.UTF8Encoding]::new($false))
    & (Get-Command node.exe -ErrorAction Stop).Source --check $js
    if($LASTEXITCODE -ne 0){throw 'Javascript invalido: no desplegado.'}

    $backup = Join-Path $root ('index.before-v85-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.html.bak')
    $workerHash = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $site -Destination $backup -ErrorAction Stop
    [IO.File]::WriteAllText($site,$html,[Text.UTF8Encoding]::new($false))
    Write-Host ('Copia de seguridad: '+$backup)
    $code = -1
    try {
        Push-Location $root
        try {
            $savedError = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $wrangler deploy --config $config
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $savedError
            }
        } finally {Pop-Location}
    } catch {
        Copy-Item -LiteralPath $backup -Destination $site -Force
        throw
    }
    if($code -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $site -Force
        throw ('Wrangler fallo ('+$code+'). Copia local restaurada.')
    }
    if((Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -cne $workerHash) {
        throw 'ALERTA: el Worker ha cambiado de forma inesperada.'
    }
    $published = $false
    for($i=0;$i -lt 8;$i++) {
        try {
            $live = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?v85='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
            if($live.Contains('PENDIENTE DE CONFIRMACI') -and $live.Contains('readyConfirmed')) {
                $published = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }
    if(-not $published) {throw 'Wrangler completo, pero no se verifico el HTML remoto.'}
    Write-Host 'TTActualidad V8.5 PUBLICADA Y VERIFICADA. Actualiza el navegador.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp,$js -Force -ErrorAction SilentlyContinue
}
