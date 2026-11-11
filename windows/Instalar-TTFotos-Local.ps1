# Instala TT Fotos Rescate desde esta carpeta, sin descargar scripts.
# Por defecto SOLO instala y audita. -Recover captura originales y los asocia localmente, SIN entregar a iPhone.
# -Serve abre panel local desde 8765; si esta ocupado, usa 8766+ sin cerrar otros procesos.
param(
  [string]$Base = 'C:\TTiTTulares',
  [switch]$Recover,
  [switch]$Serve,
  [string]$ImportDir = '',
  [string]$Since = '2026-11-10'
)
$ErrorActionPreference = 'Stop'
$origin = $PSScriptRoot
if ($Since -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'INVALID_DATE_USE_YYYY-MM-DD' }
if (!(Test-Path -LiteralPath $Base -PathType Container)) { throw 'TT_FOTOS_BASE_NOT_FOUND' }
$node = (Get-Command node -ErrorAction Stop).Source
$names = @('TTFotosRescate.cjs','TTFotosRescate.test.cjs','TTFotosRescatePanel.html')
foreach ($name in $names) {
  if (!(Test-Path -LiteralPath (Join-Path $origin $name) -PathType Leaf)) { throw ('MISSING_FILE ' + $name) }
}
& $node --check (Join-Path $origin 'TTFotosRescate.cjs')
if ($LASTEXITCODE -ne 0) { throw 'RECOVERER_SYNTAX_ERROR' }
& $node --test (Join-Path $origin 'TTFotosRescate.test.cjs')
if ($LASTEXITCODE -ne 0) { throw 'SAFETY_TESTS_FAILED_NO_INSTALL' }
foreach ($name in $names) {
  $destination = Join-Path $Base $name
  if (Test-Path -LiteralPath $destination) {
    $backup = $destination + '.before-rescate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
    Copy-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
    Write-Host ('BACKUP ' + $backup)
  }
  $tmp = $destination + '.incoming'
  Copy-Item -LiteralPath (Join-Path $origin $name) -Destination $tmp -Force
  Move-Item -LiteralPath $tmp -Destination $destination -Force
}
Write-Host 'TT_FOTOS_RESCATE_V3_INSTALLED - monitor local; iPhone inbox intacta'
$app = Join-Path $Base 'TTFotosRescate.cjs'
$arguments = @('--base', $Base, '--since', $Since)
if ([string]::IsNullOrWhiteSpace($ImportDir)) {
  $ImportDir = Join-Path $Base 'TTFotos-Importar'
  New-Item -ItemType Directory -Path $ImportDir -Force | Out-Null
}
if (![string]::IsNullOrWhiteSpace($ImportDir)) {
  if (!(Test-Path -LiteralPath $ImportDir -PathType Container)) { throw 'IMPORT_DIR_NOT_FOUND' }
  $arguments += @('--import-dir', $ImportDir)
}
if ($Recover) {
  Write-Host 'TT_FOTOS_CAPTURE_ONLY - sin envios ni cambios en iPhone'
  & $node $app --rescue --limit 8 @arguments
  if ($LASTEXITCODE -ne 0) { throw 'RECOVERY_REPORTED_ERROR' }
} else {
  Write-Host 'TT_FOTOS_INVENTORY_READ_ONLY'
  & $node $app --scan @arguments
  if ($LASTEXITCODE -ne 0) { throw 'AUDIT_REPORTED_ERROR' }
}
if ($Serve) {
  Write-Host ('TT_FOTOS_IMPORT_FOLDER ' + $ImportDir)
  Write-Host ('TT_FOTOS_FROM_DATE ' + $Since)
  Write-Host 'PANEL: usa la URL TT_FOTOS_PANEL que indique Node (8765 o 8766 si esta ocupado)'
  & $node $app --serve @arguments
} else {
  Write-Host 'PANEL: node C:\TTiTTulares\TTFotosRescate.cjs --serve --import-dir C:\TTiTTulares\TTFotos-Importar'
}