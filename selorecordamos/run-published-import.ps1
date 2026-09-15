$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$env:X_AUTH_TOKEN = [Environment]::GetEnvironmentVariable('X_AUTH_TOKEN','User')
$env:X_CT0 = [Environment]::GetEnvironmentVariable('X_CT0','User')
$env:SR_HEADLESS = '1'
$env:SR_PUBLISHED_SINCE = '2026-09-14T00:00:00+02:00'
$env:SR_PUBLISHED_PUSH = '1'
$logDir = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'published-import-task.log'
"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] Inicio historico publicado" | Add-Content $log
try {
  node (Join-Path $PSScriptRoot 'import_published.js') 2>&1 | Add-Content $log
  "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] Fin correcto" | Add-Content $log
} catch {
  "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] ERROR: $($_.Exception.Message)" | Add-Content $log
  exit 1
}
