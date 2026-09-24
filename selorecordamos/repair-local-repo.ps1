$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$taskNames = @(
    'SeLoRecordamos-Telegram',
    'SeLoRecordamos-Search',
    'SeLoRecordamos-Published',
    'SeLoRecordamos-Historico',
    'SeLoRecordamos-Watchdog'
)

Write-Host 'Deteniendo tareas SeLoRecordamos...' -ForegroundColor Cyan
foreach ($name in $taskNames) {
    try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } catch {}
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $env:TEMP ("selorecordamos-repair-" + $stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null

$requests = Join-Path $PSScriptRoot 'requests.json'
$candidates = Join-Path $PSScriptRoot 'candidates'

if (Test-Path $requests) {
    Copy-Item $requests (Join-Path $backup 'requests.json') -Force
}
if (Test-Path $candidates) {
    Copy-Item $candidates (Join-Path $backup 'candidates') -Recurse -Force
}

Write-Host ('Copia local guardada en ' + $backup)

Write-Host 'Abortando operaciones Git interrumpidas...' -ForegroundColor Cyan
& git rebase --abort 2>$null
& git merge --abort 2>$null

Write-Host 'Sincronizando main con GitHub...' -ForegroundColor Cyan
& git fetch origin main
if ($LASTEXITCODE -ne 0) { throw 'git fetch origin main ha fallado.' }

& git reset --hard origin/main
if ($LASTEXITCODE -ne 0) { throw 'git reset --hard origin/main ha fallado.' }

# Restaurar todos los candidatos locales. search_x.js descarta automáticamente
# los que ya consten en telegram-sent.json y reconstruye el outbox pendiente.
$backupCandidates = Join-Path $backup 'candidates'
if (Test-Path $backupCandidates) {
    New-Item -ItemType Directory -Force -Path $candidates | Out-Null
    Get-ChildItem $backupCandidates -Filter '*.json' -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $candidates $_.Name) -Force
    }
}

# Fusionar cualquier solicitud local que aún no hubiera llegado a GitHub.
$backupRequests = Join-Path $backup 'requests.json'
if (Test-Path $backupRequests) {
    try {
        $local = Get-Content $backupRequests -Raw | ConvertFrom-Json
        $remote = Get-Content $requests -Raw | ConvertFrom-Json

        $all = @()
        if ($remote.requests) { $all += @($remote.requests) }
        if ($local.requests) { $all += @($local.requests) }

        $seen = @{}
        $merged = New-Object System.Collections.ArrayList
        foreach ($r in $all) {
            if ($r.type -eq 'evaluate') {
                $key = 'evaluate:' + [string]$r.tweet_id
            } elseif ($r.type -eq 'telegram_instruction') {
                $key = 'telegram_instruction:' + [string]$r.telegram_update_id
            } else {
                $key = [string]$r.type + ':' + [string]$r.created_at
            }

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$merged.Add($r)
            }
        }

        $json = @{ requests = @($merged) } | ConvertTo-Json -Depth 10
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($requests, $json + [Environment]::NewLine, $utf8NoBom)

        & git add -- 'selorecordamos/requests.json'
        & git diff --cached --quiet -- 'selorecordamos/requests.json'
        if ($LASTEXITCODE -ne 0) {
            & git commit -m 'Recover local SeLoRecordamos requests' -- 'selorecordamos/requests.json'
            if ($LASTEXITCODE -ne 0) { throw 'No se pudieron guardar las solicitudes recuperadas.' }
            & git push origin main
            if ($LASTEXITCODE -ne 0) {
                & git pull --rebase --autostash origin main
                if ($LASTEXITCODE -ne 0) { throw 'No se pudo sincronizar main tras recuperar requests.' }
                & git push origin main
                if ($LASTEXITCODE -ne 0) { throw 'No se pudo publicar requests recuperado.' }
            }
        }
    } catch {
        Write-Warning ('No se pudo fusionar requests.json automáticamente: ' + $_.Exception.Message)
    }
}

Write-Host 'Repositorio local limpio y sincronizado.' -ForegroundColor Green
Write-Host ('HEAD: ' + ((& git rev-parse --short HEAD) | Out-String).Trim())

Write-Host 'Reinstalando y validando tareas...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-tasks.ps1')
if ($LASTEXITCODE -ne 0) { throw ('install-tasks.ps1 terminó con código ' + $LASTEXITCODE) }

Write-Host ''
Write-Host 'Reparación terminada.' -ForegroundColor Green
Write-Host ('Backup conservado en: ' + $backup)
