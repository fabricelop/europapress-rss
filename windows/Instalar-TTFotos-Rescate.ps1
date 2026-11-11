# TT Fotos - instalador local no destructivo del rescatador y monitor.
# Solo descarga archivos del commit fijado y ejecuta pruebas antes de copiarlos.
# Por defecto: instala, audita y NO envia ningun PNG.
# -Recover: captura SOLO conversaciones ChatGPT ya abiertas y reintenta originales exactos.
# -Serve: abre panel privado en http://127.0.0.1:8765/
param(
  [string]$Base = 'C:\TTiTTulares',
  [switch]$Recover,
  [switch]$Serve,
  [string]$ImportDir = ''
)
$ErrorActionPreference = 'Stop'
$pin = '9f24ebe32319a2ef3bff68c1587a2ad9b2bcf563'
$raw = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/' + $pin + '/windows/'
if (!(Test-Path -LiteralPath $Base -PathType Container)) { throw 'TT_FOTOS_BASE_NOT_FOUND' }
$node = (Get-Command node -ErrorAction Stop).Source
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('tt-fotos-rescate-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$names = @('TTFotosRescate.cjs', 'TTFotosRescate.test.cjs', 'TTFotosRescatePanel.html')
try {
  foreach ($name in $names) {
    $dst = Join-Path $stage $name
    Invoke-WebRequest -Uri ($raw + $name) -OutFile $dst -UseBasicParsing
    if ((Get-Item -LiteralPath $dst).Length -lt 1000) { throw ('DOWNLOAD_INCOMPLETE ' + $name) }
  }
  & $node --check (Join-Path $stage 'TTFotosRescate.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'TT_FOTOS_RECOVERER_SYNTAX_ERROR' }
  & $node --test (Join-Path $stage 'TTFotosRescate.test.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'TT_FOTOS_TESTS_FAILED_NO_INSTALL' }

  foreach ($name in $names) {
    $dest = Join-Path $Base $name
    if (Test-Path -LiteralPath $dest) {
      $backup = $dest + '.before-tt-fotos-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
      Copy-Item -LiteralPath $dest -Destination $backup -ErrorAction Stop
      Write-Host ('BACKUP ' + $backup)
    }
    $tmp = $dest + '.incoming'
    Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $dest -Force
  }
  Write-Host ('TT_FOTOS_RESCATE_INSTALLED pin=' + $pin)
  $app = Join-Path $Base 'TTFotosRescate.cjs'
  $baseArgs = @('--base', $Base)
  if (![string]::IsNullOrWhiteSpace($ImportDir)) {
    if (!(Test-Path -LiteralPath $ImportDir -PathType Container)) { throw 'IMPORT_DIR_NOT_FOUND' }
    $baseArgs += @('--import-dir', $ImportDir)
  }
  if ($Recover) {
    Write-Host 'TT_FOTOS_RECOVERY_EXACT_ONLY - no ImageGen; no publish; duplicates accepted'
    & $node $app --rescue --limit 8 @baseArgs
    if ($LASTEXITCODE -ne 0) { throw 'TT_FOTOS_RESCUE_REPORTED_ERROR' }
  } else {
    Write-Host 'TT_FOTOS_AUDIT_ONLY - no images sent'
    & $node $app --scan @baseArgs
    if ($LASTEXITCODE -ne 0) { throw 'TT_FOTOS_AUDIT_REPORTED_ERROR' }
  }
  if ($Serve) {
    Write-Host 'TT_FOTOS_PRIVATE_PANEL http://127.0.0.1:8765/'
    & $node $app --serve @baseArgs
  } else {
    Write-Host 'TO_VIEW_PANEL: node C:\TTiTTulares\TTFotosRescate.cjs --serve'
  }
} finally {
  if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}
