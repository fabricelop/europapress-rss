#requires -Version 5.1
<#
Despliegue seguro EXCLUSIVO de TTActualidad original.
Conserva Worker, URL, secretos, sesion iPhone y namespace KV.
Ejecucion desde el Windows que ya tiene Wrangler autenticado:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Actualizar-TTActualidad-Original.ps1
#>
param([switch]$PreflightOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'fabricelop/europapress-rss'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config = Join-Path $root 'wrangler.jsonc'
$site = Join-Path $root 'site\index.html'
$worker = Join-Path $root 'ttactualidad-worker.js'
$wrangler = Join-Path $root 'node_modules\.bin\wrangler.cmd'
$live = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'
$requiredKvId = '231e2ba56ef443f9be857e23a5881847'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $root ('backup-original-'+$stamp)
$stage = Join-Path $env:TEMP ('ttactualidad-original-'+[guid]::NewGuid().ToString('N'))
$changedLocal = $false
$deployed = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ensure([bool]$condition,[string]$message) {
    if (-not $condition) { throw $message }
}
function Read-Health {
    Invoke-RestMethod -Uri ($live+'health?deploy_check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 25
}
function Read-Ui {
    [string](Invoke-WebRequest -UseBasicParsing -Uri ($live+'?deploy_check='+[guid]::NewGuid().ToString('N')) -TimeoutSec 30).Content
}
function Check-Health($health) {
    Ensure (($health.ok -eq $true) -and ($health.kind -ceq 'ttactualidad-direct-live') -and
            ($health.production_connected -eq $true) -and
            ($health.session_auth -ceq 'signed_cookie_v1')) (
            'El Worker original no confirma autenticacion y conexion esperadas. No se modifica nada.')
}
function Deploy-SameWorker {
    Push-Location $root
    try {
        # Wrangler can emit benign warnings to stderr; do not mistake them
        # for an error, but require a successful native exit code.
        $oldErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $wrangler deploy --config $config
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorPreference
        }
        Ensure ($code -eq 0) ('Wrangler deploy fallo: '+$code)
    } finally {
        Pop-Location
    }
}
function Restore-Local {
    if ($changedLocal -and (Test-Path -LiteralPath (Join-Path $backup 'index.html'))) {
        Copy-Item -LiteralPath (Join-Path $backup 'index.html') -Destination $site -Force
        Copy-Item -LiteralPath (Join-Path $backup 'ttactualidad-worker.js') -Destination $worker -Force
    }
}

Write-Host '=== Actualizar la app ORIGINAL de TTActualidad en Cloudflare ===' -ForegroundColor Cyan
try {
    foreach ($file in @($site,$worker,$config,$wrangler)) {
        Ensure (Test-Path -LiteralPath $file) ('Falta archivo de la instalacion original: '+$file)
    }
    $cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
    $kv = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
    Ensure (($cfg.name -ceq 'ttactualidad-decisions-pilot') -and
            ($cfg.main -ceq './ttactualidad-worker.js') -and
            ($kv.Count -eq 1) -and
            ([string]$kv[0].id -ceq $requiredKvId)) (
            'La configuracion o KV no corresponde al Worker original. No se despliega.')
    $before = Read-Health
    Check-Health $before

    # Resolve git SHA once: backend and frontend MUST be from same commit.
    $commit = Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$repo+'/commits/main') -Headers @{'User-Agent'='TTActualidad-Original-Updater'} -TimeoutSec 30
    $pin = [string]$commit.sha
    Ensure ($pin -match '^[0-9a-f]{40}$') 'No se pudo resolver la revision exacta de GitHub.'
    $base = 'https://raw.githubusercontent.com/'+$repo+'/'+$pin+'/pilot/ttactualidad-live/'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $nextHtml = Join-Path $stage 'index.html'
    $nextWorker = Join-Path $stage 'ttactualidad-worker.js'
    Invoke-WebRequest -UseBasicParsing -Uri ($base+'index.html') -OutFile $nextHtml -TimeoutSec 60
    Invoke-WebRequest -UseBasicParsing -Uri ($base+'worker.js') -OutFile $nextWorker -TimeoutSec 60
    $html = [IO.File]::ReadAllText($nextHtml,[Text.Encoding]::UTF8)
    $js = [IO.File]::ReadAllText($nextWorker,[Text.Encoding]::UTF8)
    foreach ($marker in @('Volver a En elaboración','Top 30','Listas','TTImages',
                           'Copiar Foto Archivo','id="manual-open"','function trendRows()')) {
        Ensure ($html.Contains($marker)) ('Interfaz incompleta: '+$marker)
    }
    foreach ($marker in @('ttactualidad-direct-live','signed_cookie_v1',
                           'ttactualidad_manual_news_v1',
                           "'prepare','discard','deleted','published','rework'",
                           "'deleted','discard','prepare','rework'")) {
        Ensure ($js.Contains($marker)) ('Worker incompleto: '+$marker)
    }
    $start = $html.IndexOf('<script>')
    $end = $html.IndexOf('</script>', $start)
    Ensure (($start -ge 0) -and ($end -gt $start)) 'No se encontro el Javascript de la interfaz.'
    $uiCheck = Join-Path $stage 'ui-check.js'
    $workerCheck = Join-Path $stage 'worker-check.mjs'
    [IO.File]::WriteAllText($uiCheck,$html.Substring($start+8,$end-$start-8),$utf8)
    [IO.File]::WriteAllText($workerCheck,$js,$utf8)
    & (Get-Command node.exe -ErrorAction Stop).Source --check $uiCheck
    Ensure ($LASTEXITCODE -eq 0) 'Javascript de la interfaz invalido.'
    & (Get-Command node.exe -ErrorAction Stop).Source --check $workerCheck
    Ensure ($LASTEXITCODE -eq 0) 'Javascript del Worker invalido.'

    Write-Host ('Preflight OK. Revision '+$pin.Substring(0,12)+'. Configuracion y KV intactos.') -ForegroundColor Green
    if ($PreflightOnly) { return }
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Copy-Item -LiteralPath $site -Destination (Join-Path $backup 'index.html') -ErrorAction Stop
    Copy-Item -LiteralPath $worker -Destination (Join-Path $backup 'ttactualidad-worker.js') -ErrorAction Stop
    Copy-Item -LiteralPath $nextHtml -Destination $site -Force
    $changedLocal = $true
    Copy-Item -LiteralPath $nextWorker -Destination $worker -Force
    Write-Host 'Publicando interfaz y Worker en la URL original, sin cambiar KV ni secretos...'
    Deploy-SameWorker
    $deployed = $true

    $valid = $false
    for ($attempt=0; $attempt -lt 6; $attempt++) {
        try {
            $after = Read-Health
            $remote = Read-Ui
            if ($after.ok -eq $true -and $after.kind -ceq $before.kind -and
                $after.session_auth -ceq $before.session_auth -and
                $after.production_connected -eq $true -and
                $remote.Contains('Volver a En elaboración') -and
                $remote.Contains('function trendRows()') -and
                $remote.Contains('TTImages')) {
                $valid = $true
                break
            }
        } catch {
            Write-Warning ('Verificacion intento '+($attempt+1)+': '+$_.Exception.Message)
        }
        Start-Sleep -Seconds 3
    }
    Ensure $valid 'El despliegue no pudo verificarse en la URL original.'
    Write-Host 'TT_ACTUALIDAD_ORIGINAL_PUBLICADA_Y_VERIFICADA' -ForegroundColor Green
    Write-Host ('URL: '+$live)
    Write-Host ('Respaldo: '+$backup)
} catch {
    Write-Warning ('Actualizacion no completada: '+$_.Exception.Message)
    try {
        Restore-Local
        if ($deployed) {
            Write-Warning 'Intentando restaurar la version anterior tambien en Cloudflare.'
            Deploy-SameWorker
            Write-Warning 'Se intento restaurar la version anterior.'
        }
    } catch {
        Write-Warning ('Restauracion no confirmada: '+$_.Exception.Message)
    }
    throw
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
