# Staging-only install. DOES NOT install Meta tokens, change Telegram/X, or switch existing webhooks.
# Run from a clean checkout of PR #112: powershell -ExecutionPolicy Bypass -File .\scripts\install-preview.ps1
[CmdletBinding()]
param([switch]$Deploy)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $folder "..")).Path
Push-Location $root
try {
    $config = Get-Content ".\wrangler.jsonc" -Raw | ConvertFrom-Json
    if ($config.name -ne "tt-actualidad-instagram-pilot") {
        throw "Worker incorrecto; no se modificará otro servicio."
    }
    if ($config.d1_databases[0].database_id -ne "4eacd44c-212c-4a49-a907-fbbf561b969f") {
        throw "La conexión D1 no corresponde a TT Actualidad."
    }

    npm.cmd install --no-audit --no-fund --ignore-scripts
    if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

    npm.cmd test
    if ($LASTEXITCODE -ne 0) { throw "Node tests failed" }

    npx.cmd wrangler deploy --dry-run
    if ($LASTEXITCODE -ne 0) { throw "Worker dry-run failed" }

    if (-not $Deploy) {
        Write-Host "OK: comprobación completada. Nada se ha desplegado."
        Write-Host "Para desplegar SOLO el nuevo Worker de pruebas: .\scripts\install-preview.ps1 -Deploy"
        exit 0
    }

    Write-Host "Desplegando únicamente el Worker de pruebas tt-actualidad-instagram-pilot, SIN credenciales Meta."
    npx.cmd wrangler deploy
    if ($LASTEXITCODE -ne 0) { throw "Wrangler deploy failed" }
    Write-Host "Despliegue de pruebas terminado. No activa ningún botón ni publica en Instagram."
} finally {
    Pop-Location
}
