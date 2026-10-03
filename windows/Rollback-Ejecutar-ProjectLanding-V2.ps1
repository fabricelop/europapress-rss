param(
  [Parameter(Mandatory=$true)]
  [string]$BackupPath
)

$ErrorActionPreference = "Stop"
$BaseDir = [IO.Path]::GetFullPath("C:\TTiTTulares")
$Target = Join-Path $BaseDir "Ejecutar.js"
$ResolvedBackup = [IO.Path]::GetFullPath($BackupPath)

if (-not $ResolvedBackup.StartsWith($BaseDir + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
  throw "El backup debe estar dentro de C:\TTiTTulares"
}
if ([IO.Path]::GetFileName($ResolvedBackup) -notlike 'Ejecutar.js.before-project-landing-v2-*.bak') {
  throw "Nombre de backup no valido para este rollback"
}
if (-not (Test-Path -LiteralPath $ResolvedBackup -PathType Leaf)) {
  throw "No existe el backup: $ResolvedBackup"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe" }
& $node.Source --check $ResolvedBackup
if ($LASTEXITCODE -ne 0) { throw "El backup no supera node --check" }

$safety = $Target + ".before-rollback-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $safety -Force
Copy-Item -LiteralPath $ResolvedBackup -Destination $Target -Force
& $node.Source --check $Target
if ($LASTEXITCODE -ne 0) {
  Copy-Item -LiteralPath $safety -Destination $Target -Force
  throw "El rollback fallo la validacion; se restauro el runner anterior"
}

Write-Host "ROLLBACK COMPLETADO" -ForegroundColor Green
Write-Host "Restaurado: $ResolvedBackup"
Write-Host "Backup de seguridad previo al rollback: $safety"
