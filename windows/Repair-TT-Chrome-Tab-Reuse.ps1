# Repair-TT-Chrome-Tab-Reuse.ps1
# Installs validated browser-tab reuse fixes without touching live Chrome or jobs.
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$base = 'C:\TTiTTulares'
$repo = Split-Path -Parent $PSScriptRoot
$names = @('TTiTTularesImageBridge.js', 'TTendenciasImageBridge.js')
$node = Get-Command 'node.exe' -ErrorAction Stop

$running = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -eq 'node.exe' -and
    [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge\.js'
})
if ($running.Count -gt 0) {
    Write-Host "Instalacion pospuesta: hay $($running.Count) bridge(s) de imagen activo(s)." -ForegroundColor Yellow
    $running | Select-Object ProcessId, CommandLine | Format-Table -AutoSize
    exit 2
}

$items = @()
foreach ($name in $names) {
    $source = Join-Path (Join-Path $repo 'windows') $name
    $target = Join-Path $base $name
    if (-not (Test-Path -LiteralPath $source)) { throw "No existe el archivo actualizado: $source" }
    if (-not (Test-Path -LiteralPath $target)) { throw "No existe el bridge local: $target" }
    $text = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    foreach ($marker in @(
        'BRIDGE FIXED TAB RETAINED AFTER ERROR',
        'BRIDGE FIXED TAB RECOVERED LOST ACK',
        'BRIDGE FIXED TAB REUSE'
    )) {
        if (-not $text.Contains($marker)) { throw "Falta marcador de seguridad $marker en $name" }
    }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $node.Source --check $source 1>$null 2>$null
        $check = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($check -ne 0) { throw "Sintaxis JavaScript invalida en $name" }
    $newHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $oldHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $items += [pscustomobject]@{ Name = $name; Source = $source; Target = $target; Different = ($newHash -ne $oldHash) }
}
Write-Host "`n=== ESTADO DE LOS BRIDGES ==="
$items | Select-Object Name, Different | Format-Table -AutoSize

if ($CheckOnly) {
    Write-Host 'Solo comprobacion. No se ha modificado ningun archivo.'
    exit 0
}

# Recheck no bridge started between validation and copying.
$busyNow = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -eq 'node.exe' -and
    [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge\.js'
})
if ($busyNow.Count -gt 0) { throw 'Se ha iniciado una imagen; instalacion pospuesta para no interferir.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backups = @()
try {
    foreach ($item in $items | Where-Object Different) {
        $backup = $item.Target + '.backup-' + $stamp
        Copy-Item -LiteralPath $item.Target -Destination $backup -ErrorAction Stop
        $backups += [pscustomobject]@{ Target = $item.Target; Backup = $backup }
    }
    foreach ($item in $items | Where-Object Different) {
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force -ErrorAction Stop
        Write-Host "INSTALADO $($item.Name)" -ForegroundColor Green
    }
} catch {
    foreach ($entry in $backups) {
        try { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Target -Force -ErrorAction Stop } catch {}
    }
    throw
}

Write-Host 'Instalacion terminada. Copias de seguridad conservadas.'
Write-Host 'No se han cerrado Chrome, pestañas, listeners ni colas de trabajo.'
Write-Host 'TTendencias creara una nueva pestaña fija solo si confirma que la anterior ha desaparecido.'

try {
    $raw = (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9223/json/list' -TimeoutSec 5).Content
    $parsed = ConvertFrom-Json -InputObject $raw
    $rows = @()
    foreach ($entry in $parsed) {
        if ($entry -is [array]) { $rows += $entry } else { $rows += $entry }
    }
    $pages = @($rows | Where-Object { $_.type -eq 'page' -and [string]$_.url -like 'https://chatgpt.com*' })
    Write-Host "Pestañas ChatGPT actuales en 9223: $($pages.Count)"
} catch {
    Write-Host "No se pudo consultar CDP: $($_.Exception.Message)" -ForegroundColor Yellow
}
