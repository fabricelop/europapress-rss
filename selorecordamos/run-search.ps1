$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$utf8 = New-Object System.Text.UTF8Encoding($true)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$env:X_AUTH_TOKEN = [Environment]::GetEnvironmentVariable('X_AUTH_TOKEN', 'User')
$env:X_CT0 = [Environment]::GetEnvironmentVariable('X_CT0', 'User')
$env:SR_TELEGRAM_BOT_TOKEN = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_BOT_TOKEN', 'User')
$env:SR_TELEGRAM_CHAT_ID = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_CHAT_ID', 'User')
$env:SR_HEADLESS = '1'
$env:SR_BACKFILL_DAYS = '0'

$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$log = Join-Path $runtime 'search-task.log'

function Ensure-Utf8BomLog {
    if (-not (Test-Path $log)) {
        [System.IO.File]::WriteAllText($log, '', $utf8)
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($log)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        $legacy = Join-Path $runtime 'search-task-legacy.log'
        Move-Item -Force $log $legacy
        [System.IO.File]::WriteAllText($log, '', $utf8)
    }
}

Ensure-Utf8BomLog

function Add-LogLine([string]$text) {
    [System.IO.File]::AppendAllText($log, $text + [Environment]::NewLine, $utf8)
}

function Quote-Arg([string]$arg) {
    if ($null -eq $arg) { return '""' }
    return '"' + ($arg -replace '"', '\"') + '"'
}

function Run-NodeToLog([string[]]$arguments, [int]$timeoutSeconds = 0) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'node.exe'
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    if ($timeoutSeconds -gt 0) {
        $finished = $p.WaitForExit($timeoutSeconds * 1000)
        if (-not $finished) {
            # taskkill /T termina tambien Chrome y los demas descendientes de Playwright.
            # Kill() solo terminaba Node y podia dejar navegadores huerfanos.
            try {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null
            } catch {
                try { $p.Kill() } catch {}
            }
            [void]$p.WaitForExit(15000)
            if (-not $p.HasExited) {
                Add-LogLine "[$(Get-Date -Format s)] ERROR: no se pudo detener el arbol Node PID=$($p.Id)"
                $p.Dispose()
                return 124
            }
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            if ($stdout) { [System.IO.File]::AppendAllText($log, $stdout, $utf8) }
            if ($stderr) { [System.IO.File]::AppendAllText($log, $stderr, $utf8) }
            Add-LogLine "[$(Get-Date -Format s)] TIMEOUT node tras $timeoutSeconds s: $($arguments -join ' ')"
            $p.Dispose()
            return 124
        }
    } else {
        $p.WaitForExit()
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $p.ExitCode
    $p.Dispose()

    if ($stdout) { [System.IO.File]::AppendAllText($log, $stdout, $utf8) }
    if ($stderr) { [System.IO.File]::AppendAllText($log, $stderr, $utf8) }
    return $exitCode
}

try {
    Add-LogLine "[$(Get-Date -Format s)] Inicio busqueda"
    $searchCode = Run-NodeToLog @((Join-Path $PSScriptRoot 'search_x.js')) 240
    # Publicar SIEMPRE el diagnóstico, también cuando X ha rechazado la
    # navegación; nunca dejar un reporte antiguo que aparente estar sano.
    $reportCode = Run-NodeToLog @((Join-Path $PSScriptRoot 'publish_search_report.js')) 90
    if ($reportCode -ne 0) { throw "publish_search_report.js termino con codigo $reportCode" }
    if ($searchCode -ne 0) { throw "search_x.js termino con codigo $searchCode; resultado publicado" }

    Add-LogLine "[$(Get-Date -Format s)] Outbox delegado al listener Telegram continuo."

    Add-LogLine "[$(Get-Date -Format s)] Comprobando listener SLR"
    try {
        $listener = Get-ScheduledTask -TaskName 'SeLoRecordamos-Telegram' -ErrorAction Stop
        if ($listener.State -ne 'Running') {
            Start-ScheduledTask -TaskName 'SeLoRecordamos-Telegram'
            Add-LogLine "[$(Get-Date -Format s)] Listener reactivado"
        } else {
            Add-LogLine "[$(Get-Date -Format s)] Listener ya estaba activo"
        }
    } catch {
        Add-LogLine "[$(Get-Date -Format s)] AVISO listener: $($_.Exception.Message)"
    }

    Add-LogLine "[$(Get-Date -Format s)] Fin correcto"
}
catch {
    Add-LogLine "[$(Get-Date -Format s)] ERROR: $($_.Exception.Message)"
    exit 1
}
