# Apply-TT-CurrentUI-Fix.ps1
# One-shot repair for current ChatGPT project UI.
# 1) Applies persistent project chat runner patch to clean baseline Ejecutar.js.
# 2) Runs current listener recovery (which does NOT modify Ejecutar.js).
# 3) Verifies marker and listener files.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"

function Get-MainFile([string]$RepoPath,[string]$OutFile) {
  $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + $RepoPath + "?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $doc = Invoke-RestMethod -Uri $api -Headers @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "TT-current-ui-fix"
    "Cache-Control" = "no-cache"
  } -TimeoutSec 20
  if (-not $doc.content) { throw "GitHub API sin contenido para $RepoPath" }
  [IO.File]::WriteAllBytes($OutFile,[Convert]::FromBase64String(([string]$doc.content -replace "\s","")))
}

function Validate-Ps([string]$File) {
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($File,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido: $($e[0].Message)"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$patch = Join-Path $BaseDir "Fix-Ejecutar-PersistentProjectChat-V1.ps1"
Get-MainFile "windows/Fix-Ejecutar-PersistentProjectChat-V1.ps1" $patch
Validate-Ps $patch
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patch
if ($LASTEXITCODE -ne 0) { throw "Falló Fix-Ejecutar-PersistentProjectChat-V1.ps1" }

$runner = Join-Path $BaseDir "Ejecutar.js"
$runnerText = Get-Content -LiteralPath $runner -Raw -Encoding UTF8
if (-not $runnerText.Contains("TT_PERSISTENT_PROJECT_CHAT_V1")) {
  throw "Ejecutar.js no contiene TT_PERSISTENT_PROJECT_CHAT_V1"
}

$recovery = Join-Path $BaseDir "Recover-TT-Execution.ps1"
Get-MainFile "windows/Recover-TT-Execution.ps1" $recovery
Validate-Ps $recovery
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recovery
if ($LASTEXITCODE -ne 0) { throw "Falló Recover-TT-Execution.ps1" }

Write-Host ""
Write-Host "TT CURRENT UI FIX ACTIVO" -ForegroundColor Green
Write-Host "Runner: TT_PERSISTENT_PROJECT_CHAT_V1"
Write-Host "Recovery: listeners actuales, Ejecutar.js no modificado"
Write-Host "Siguiente paso: lanzar TTendencias UNA vez."
