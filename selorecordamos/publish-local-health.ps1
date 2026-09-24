$ErrorActionPreference = 'Continue'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$runtime = Join-Path $PSScriptRoot 'runtime'
$healthPath = Join-Path $PSScriptRoot 'local-health.json'
$healthRepoPath = 'selorecordamos/local-health.json'
$taskNames = @(
    'SeLoRecordamos-Telegram',
    'SeLoRecordamos-Search',
    'SeLoRecordamos-Published',
    'SeLoRecordamos-Watchdog'
)

function Tail-Text([string]$name, [int]$lines = 30) {
    $file = Join-Path $runtime $name
    if (-not (Test-Path $file)) { return @() }
    try { return @(Get-Content -Path $file -Tail $lines -ErrorAction Stop) }
    catch { return @("ERROR leyendo $name: $($_.Exception.Message)") }
}

$tasks = @()
foreach ($name in $taskNames) {
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop
        $tasks += [ordered]@{
            name = $name
            state = [string]$task.State
            enabled = [bool]$task.Settings.Enabled
            last_run_time = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('o') } else { $null }
            last_task_result = [int64]$info.LastTaskResult
            next_run_time = if ($info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime.ToString('o') } else { $null }
        }
    } catch {
        $tasks += [ordered]@{
            name = $name
            state = 'missing_or_error'
            error = $_.Exception.Message
        }
    }
}

$health = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    computer = $env:COMPUTERNAME
    user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    env_present = [ordered]@{
        X_AUTH_TOKEN = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('X_AUTH_TOKEN','User'))
        X_CT0 = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('X_CT0','User'))
        SR_TELEGRAM_BOT_TOKEN = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SR_TELEGRAM_BOT_TOKEN','User'))
        SR_TELEGRAM_CHAT_ID = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SR_TELEGRAM_CHAT_ID','User'))
    }
    tasks = $tasks
    logs = [ordered]@{
        search = Tail-Text 'search-task.log' 40
        published = Tail-Text 'published-import-task.log' 40
        telegram = Tail-Text 'telegram-listener.log' 40
        watchdog = Tail-Text 'watchdog.log' 40
    }
}

$health | ConvertTo-Json -Depth 8 | Set-Content -Path $healthPath -Encoding UTF8

try {
    & git add -- $healthRepoPath
    & git diff --cached --quiet -- $healthRepoPath
    if ($LASTEXITCODE -ne 0) {
        & git commit -m 'Update SeLoRecordamos local health' -- $healthRepoPath
        if ($LASTEXITCODE -ne 0) { throw "git commit fallo con codigo $LASTEXITCODE" }

        & git push origin main
        if ($LASTEXITCODE -ne 0) {
            & git pull --rebase --autostash origin main
            if ($LASTEXITCODE -ne 0) { throw "git pull --rebase fallo con codigo $LASTEXITCODE" }
            & git push origin main
            if ($LASTEXITCODE -ne 0) { throw "git push fallo con codigo $LASTEXITCODE" }
        }
    }
    Write-Host 'Estado local SeLoRecordamos publicado en GitHub.' -ForegroundColor Green
} catch {
    Write-Warning ("No se pudo publicar local-health.json: " + $_.Exception.Message)
}

Write-Host ''
Write-Host 'Resumen local:' -ForegroundColor Cyan
$tasks | ForEach-Object {
    if ($_.state -eq 'missing_or_error') {
        Write-Host ("- " + $_.name + ": ERROR - " + $_.error)
    } else {
        Write-Host ("- " + $_.name + ": " + $_.state + " | LastResult=" + $_.last_task_result + " | Last=" + $_.last_run_time + " | Next=" + $_.next_run_time)
    }
}
