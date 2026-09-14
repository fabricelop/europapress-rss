$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$env:X_AUTH_TOKEN = [Environment]::GetEnvironmentVariable('X_AUTH_TOKEN', 'User')
$env:X_CT0 = [Environment]::GetEnvironmentVariable('X_CT0', 'User')
$env:SR_TELEGRAM_BOT_TOKEN = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_BOT_TOKEN', 'User')
$env:SR_TELEGRAM_CHAT_ID = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_CHAT_ID', 'User')
$env:SR_HEADLESS = '1'

$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$log = Join-Path $runtime 'search-task.log'

try {
    "[$(Get-Date -Format s)] Inicio búsqueda" | Add-Content $log
    & node (Join-Path $PSScriptRoot 'search_x.js') *>> $log
    if ($LASTEXITCODE -ne 0) { throw "search_x.js terminó con código $LASTEXITCODE" }

    & node (Join-Path $PSScriptRoot 'telegram_local.js') send *>> $log
    if ($LASTEXITCODE -ne 0) { throw "telegram_local.js send terminó con código $LASTEXITCODE" }

    "[$(Get-Date -Format s)] Fin correcto" | Add-Content $log
}
catch {
    "[$(Get-Date -Format s)] ERROR: $($_.Exception.Message)" | Add-Content $log
    exit 1
}
