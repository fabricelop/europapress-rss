$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -Path $runtime -ItemType Directory -Force | Out-Null
$log = Join-Path $runtime 'editorial-local.log'
$lock = Join-Path $runtime 'editorial-local.lock'
$handle = $null
try {
    $handle = [System.IO.File]::Open($lock,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
} catch { exit 0 }
try {
    Set-Location $repo
    & git pull --rebase --autostash origin main *>> $log
    if ($LASTEXITCODE -ne 0) { throw 'git pull falló; no se modifica estado' }
    & python (Join-Path $PSScriptRoot 'editorial_local.py') *>> $log
    $editorialExit = $LASTEXITCODE
    & git add -- selorecordamos/assistant-output.json selorecordamos/assistant-state.json
    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        & git commit -m 'SeLoRecordamos: evaluaciones locales' *>> $log
        if ($LASTEXITCODE -ne 0) { throw 'git commit falló' }
        for ($i=0; $i -lt 4; $i++) {
            & git push origin HEAD:main *>> $log
            if ($LASTEXITCODE -eq 0) { break }
            & git pull --rebase --autostash origin main *>> $log
            if ($LASTEXITCODE -ne 0) { throw 'git rebase falló' }
        }
        if ($LASTEXITCODE -ne 0) { throw 'git push falló tras 4 intentos' }
    }
    if ($editorialExit -ne 0) { throw 'Quedan evaluaciones sin redactar; revisar Ollama/modelo' }
} catch {
    ('['+(Get-Date -Format s)+'] ERROR '+$_.Exception.Message) | Add-Content $log
    exit 1
} finally { if ($handle) { $handle.Dispose() } }
