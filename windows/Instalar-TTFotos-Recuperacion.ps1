# Instala la auditoria y recuperacion exacta de originales TT Fotos.
# Por defecto instala y audita SIN enviar originales.
# -DeliverCached reintenta entregas privadas ya conservadas, sin generar.
param(
  [string]$Base = 'C:\TTiTTulares',
  [switch]$DeliverCached
)
$ErrorActionPreference = 'Stop'
$pin = '3146732359a888b96a03ab92ae26b0550e7f44a3'
$root = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/' + $pin + '/windows/'
if (!(Test-Path -LiteralPath $Base -PathType Container)) { throw 'TT_BASE_NOT_FOUND' }
$node = Get-Command node -ErrorAction Stop
$version = & $node.Source --version
if ($LASTEXITCODE -ne 0) { throw 'NODE_UNAVAILABLE' }
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('tt-fotos-stage-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$source = Join-Path $stage 'TTFotosRecover.cjs'
$test = Join-Path $stage 'TTFotosRecover.test.cjs'
$dest = Join-Path $Base 'TTFotosRecover.cjs'
$backup = $null
try {
  Invoke-WebRequest -Uri ($root + 'TTFotosRecover.cjs') -OutFile $source -UseBasicParsing
  Invoke-WebRequest -Uri ($root + 'TTFotosRecover.test.cjs') -OutFile $test -UseBasicParsing
  if ((Get-Item -LiteralPath $source).Length -lt 8000 -or
      (Get-Item -LiteralPath $test).Length -lt 4500) { throw 'DOWNLOAD_INCOMPLETE' }
  & $node.Source --check $source
  if ($LASTEXITCODE -ne 0) { throw 'RECOVERER_SYNTAX_INVALID' }
  & $node.Source --check $test
  if ($LASTEXITCODE -ne 0) { throw 'TEST_SYNTAX_INVALID' }
  & $node.Source --test $test
  if ($LASTEXITCODE -ne 0) { throw 'SAFETY_TESTS_FAILED_NOT_INSTALLED' }
  if (Test-Path -LiteralPath $dest) {
    $backup = Join-Path $Base ('TTFotosRecover.cjs.before-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')
    Copy-Item -LiteralPath $dest -Destination $backup -ErrorAction Stop
  }
  $new = $dest + '.new'
  Copy-Item -LiteralPath $source -Destination $new -Force
  Move-Item -LiteralPath $new -Destination $dest -Force
  Write-Host ('TT_FOTOS_INSTALLED pin='+$pin+' node='+$version)
  if ($backup) { Write-Host ('BACKUP '+$backup) }
  if ($DeliverCached) {
    Write-Host 'TT_FOTOS_REDELIVERY_STARTED - exact conserved PNG only; duplicates accepted.'
    & $node.Source $dest --apply-cached --base $Base
    if ($LASTEXITCODE -ne 0) { throw 'PRIVATE_REDELIVERY_FAILED' }
    Write-Host 'TT_FOTOS_REDELIVERY_CHECK_OUTPUT_FOR_INDIVIDUAL_FAILURES'
  } else {
    Write-Host 'TT_FOTOS_READONLY_AUDIT_STARTED'
    & $node.Source $dest --audit --base $Base
    if ($LASTEXITCODE -ne 0) { throw 'TT_FOTOS_AUDIT_FAILED' }
    Write-Host 'TO_REDELIVER: node C:\TTiTTulares\TTFotosRecover.cjs --apply-cached'
  }
} finally {
  if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}
