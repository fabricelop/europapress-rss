#requires -Version 5.1
<#
TT Actualidad +Noticia. Deploy ONLY existing ttactualidad-decisions-pilot.
Keeps the current Cloudflare KV ID, secrets, session cookies, GitHub bridge and other applications.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\Deploy-TTActualidad-PlusNoticia.ps1
#>
param([switch]$PreflightOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$url = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$pin = '492d6f77531755270dcbc98d1129d2232c5ed54f'
$base = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$pin+'/pilot/ttactualidad-live/'
Write-Host '=== TT Actualidad: despliegue aislado de +Noticia ===' -ForegroundColor Cyan

foreach($pathItem in @($config,$site,$worker,$wrangler)){
    if(-not (Test-Path -LiteralPath $pathItem)) { throw ('Falta archivo local: '+$pathItem) }
}
$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or
   $cfg.main -cne './ttactualidad-worker.js' -or
   @($cfg.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or
   [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
    throw 'Configuración no coincide con el Worker/KV validado. No se modifica nada.'
}
$oldHealth = Invoke-RestMethod -Uri ($url+'health?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
if(-not $oldHealth.ok -or $oldHealth.kind -cne 'ttactualidad-direct-live' -or
   $oldHealth.production_connected -ne $true -or
   $oldHealth.session_auth -cne 'signed_cookie_v1' -or
   $oldHealth.version -cne 'v8.1-kv-conflict-fix'){
    throw 'El Worker vivo ya no coincide con V8.5 seguro; despliegue cancelado.'
}
$oldPage = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
foreach($mark in @('TTImages','Pasar a En Elaboraci','Tremending','Copiar GAG Completo')){
    if(-not $oldPage.Contains($mark)){throw ('Interfaz viva distinta: '+$mark)}
}
$temp = Join-Path $env:TEMP ('ttactualidad-plusnoticia-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$deployed = $false
$backupSite = $null
$backupWorker = $null
try{
    $nextHtml = Join-Path $temp 'index.html'
    $nextWorker = Join-Path $temp 'ttactualidad-worker.js'
    Invoke-WebRequest -UseBasicParsing -Uri ($base+'index.html') -OutFile $nextHtml -TimeoutSec 50
    Invoke-WebRequest -UseBasicParsing -Uri ($base+'worker.js') -OutFile $nextWorker -TimeoutSec 50
    $html = [IO.File]::ReadAllText($nextHtml,[Text.Encoding]::UTF8)
    $js = [IO.File]::ReadAllText($nextWorker,[Text.Encoding]::UTF8)
    foreach($mark in @('id="manual-open"','/api/manual-news','id="manual-instructions"',
                        'TTImages','Tremending','Pasar a En Elaboraci')){
        if(-not $html.Contains($mark)){throw ('UI incompleta: '+$mark)}
    }
    foreach($mark in @('ttactualidad_manual_news_v1','editorial_dispatch_unavailable',
                         'signed_cookie_v1','ttactualidad-direct-live',"route==='/api/decision'")){
        if(-not $js.Contains($mark)){throw ('Worker incompleto: '+$mark)}
    }
    $start = $html.IndexOf('<script>')
    $end = $html.IndexOf('</script>',$start)
    if($start -lt 0 -or $end -le $start){throw 'JS de TTActualidad ausente'}
    $uiCheck = Join-Path $temp 'ui-check.js'
    $workerCheck = Join-Path $temp 'worker-check.mjs'
    [IO.File]::WriteAllText($uiCheck,$html.Substring($start+8,$end-$start-8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($workerCheck,$js,[Text.UTF8Encoding]::new($false))
    & node.exe --check $uiCheck
    if($LASTEXITCODE -ne 0){throw 'Error de sintaxis en interfaz'}
    & node.exe --check $workerCheck
    if($LASTEXITCODE -ne 0){throw 'Error de sintaxis en Worker'}

    Write-Host 'Comprobados: versión V8.5, KV, autenticación, interfaz y sintaxis JS.' -ForegroundColor Green
    if($PreflightOnly){ Write-Host 'Preflight OK. No se ha desplegado nada.'; return }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupSite = Join-Path $root ('index.before-plusnoticia-'+$stamp+'.bak')
    $backupWorker = Join-Path $root ('worker.before-plusnoticia-'+$stamp+'.bak')
    Copy-Item -LiteralPath $site -Destination $backupSite -ErrorAction Stop
    Copy-Item -LiteralPath $worker -Destination $backupWorker -ErrorAction Stop
    Copy-Item -LiteralPath $nextHtml -Destination $site -Force
    Copy-Item -LiteralPath $nextWorker -Destination $worker -Force
    Push-Location $root
    try {
        & $wrangler deploy --config $config
        if($LASTEXITCODE -ne 0){throw ('Wrangler falló con código '+$LASTEXITCODE)}
        $deployed = $true
    } finally { Pop-Location }

    $newHealth = Invoke-RestMethod -Uri ($url+'health?plusnoticia='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
    $newPage = (Invoke-WebRequest -UseBasicParsing -Uri ($url+'?plusnoticia='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25).Content
    if(-not $newHealth.ok -or $newHealth.kind -cne $oldHealth.kind -or
       $newHealth.version -cne $oldHealth.version -or
       $newHealth.production_connected -ne $true -or
       $newHealth.session_auth -cne $oldHealth.session_auth -or
       -not $newPage.Contains('id="manual-open"') -or
       -not $newPage.Contains('/api/manual-news') -or
       -not $newPage.Contains('TTImages')){
        throw 'No se verificó la UI +Noticia tras el despliegue.'
    }
    Write-Host 'TT Actualidad +Noticia publicada en el mismo Worker y URL.' -ForegroundColor Green
    Write-Host 'Comprueba una noticia real desde TTiTTulares > +Noticia.'
    Write-Host ('Copias de seguridad: '+$backupSite+' y '+$backupWorker)
}catch{
    if($backupSite -and (Test-Path -LiteralPath $backupSite)){
        Copy-Item -LiteralPath $backupSite -Destination $site -Force
        Copy-Item -LiteralPath $backupWorker -Destination $worker -Force
        if($deployed){
            Write-Warning 'La verificación falló; intentando restaurar también el Worker anterior.'
            try {
                Push-Location $root
                try { & $wrangler deploy --config $config
                    if($LASTEXITCODE -ne 0){throw 'No se pudo desplegar el respaldo'}
                } finally {Pop-Location}
            }catch {Write-Warning ('La restauración remota requiere revisión: '+$_)}
        }
    }
    throw
}finally{
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
