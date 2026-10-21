$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Invoke-Git {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git.exe'
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($Arguments | ForEach-Object {
        '"' + ($_ -replace '"','\"') + '"'
    }) -join ' ')

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $code = $p.ExitCode
    $p.Dispose()

    if (-not $Quiet) {
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() }
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("git " + ($Arguments -join ' ') + " termino con codigo " + $code + ": " + $stderr.Trim())
    }

    return [PSCustomObject]@{
        ExitCode = $code
        StdOut = $stdout
        StdErr = $stderr
    }
}

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

Write-Host 'Limpiando operaciones Git interrumpidas...' -ForegroundColor Cyan
$gitDirRaw = (Invoke-Git -Arguments @('rev-parse','--git-dir') -Quiet).StdOut.Trim()
if (-not $gitDirRaw) { throw 'No se pudo localizar .git.' }
$gitDir = if ([System.IO.Path]::IsPathRooted($gitDirRaw)) { $gitDirRaw } else { Join-Path $repo $gitDirRaw }

if ((Test-Path (Join-Path $gitDir 'rebase-merge')) -or (Test-Path (Join-Path $gitDir 'rebase-apply'))) {
    $r = Invoke-Git -Arguments @('rebase','--abort') -AllowFailure
    if ($r.ExitCode -ne 0) { [void](Invoke-Git -Arguments @('rebase','--quit') -AllowFailure) }
    Write-Host 'Rebase interrumpido limpiado.'
}

if (Test-Path (Join-Path $gitDir 'MERGE_HEAD')) {
    $r = Invoke-Git -Arguments @('merge','--abort') -AllowFailure
    if ($r.ExitCode -ne 0) { [void](Invoke-Git -Arguments @('reset','--merge','HEAD') -AllowFailure) }
    Write-Host 'Merge interrumpido limpiado.'
}

Write-Host 'Sincronizando main con GitHub...' -ForegroundColor Cyan
[void](Invoke-Git -Arguments @('fetch','origin','main'))
[void](Invoke-Git -Arguments @('reset','--hard','origin/main'))

# Restaurar todos los candidatos locales. search_x.js descarta automaticamente
# los que ya consten en telegram-sent.json y reconstruye el outbox pendiente.
$backupCandidates = Join-Path $backup 'candidates'
if (Test-Path $backupCandidates) {
    New-Item -ItemType Directory -Force -Path $candidates | Out-Null
    Get-ChildItem $backupCandidates -Filter '*.json' -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $candidates $_.Name) -Force
    }
}

# Fusionar cualquier solicitud local que aun no hubiera llegado a GitHub.
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

        [void](Invoke-Git -Arguments @('add','--','selorecordamos/requests.json'))
        $diff = Invoke-Git -Arguments @('diff','--cached','--quiet','--','selorecordamos/requests.json') -AllowFailure -Quiet
        if ($diff.ExitCode -ne 0) {
            [void](Invoke-Git -Arguments @('commit','-m','Recover local SeLoRecordamos requests','--','selorecordamos/requests.json'))
            $push = Invoke-Git -Arguments @('push','origin','main') -AllowFailure
            if ($push.ExitCode -ne 0) {
                [void](Invoke-Git -Arguments @('pull','--rebase','--autostash','origin','main'))
                [void](Invoke-Git -Arguments @('push','origin','main'))
            }
        }
    } catch {
        Write-Warning ('No se pudo fusionar requests.json automaticamente: ' + $_.Exception.Message)
    }
}

Write-Host 'Repositorio local limpio y sincronizado.' -ForegroundColor Green
$head = (Invoke-Git -Arguments @('rev-parse','--short','HEAD') -Quiet).StdOut.Trim()
Write-Host ('HEAD: ' + $head)

Write-Host 'Reinstalando y validando tareas...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-tasks.ps1')
if ($LASTEXITCODE -ne 0) { throw ('install-tasks.ps1 termino con codigo ' + $LASTEXITCODE) }

Write-Host ''
Write-Host 'Reparacion terminada.' -ForegroundColor Green
Write-Host ('Backup conservado en: ' + $backup)
