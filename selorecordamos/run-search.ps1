$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$env:X_AUTH_TOKEN = [Environment]::GetEnvironmentVariable('X_AUTH_TOKEN', 'User')
$env:X_CT0 = [Environment]::GetEnvironmentVariable('X_CT0', 'User')
$env:SR_TELEGRAM_BOT_TOKEN = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_BOT_TOKEN', 'User')
$env:SR_TELEGRAM_CHAT_ID = [Environment]::GetEnvironmentVariable('SR_TELEGRAM_CHAT_ID', 'User')
$env:SR_HEADLESS = '1'

$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$log = Join-Path $runtime 'search-task.log'

function Add-LogLine([string]$text) {
    [System.IO.File]::AppendAllText($log, $text + [Environment]::NewLine, $utf8)
}

function Quote-Arg([string]$arg) {
    if ($null -eq $arg) { return '""' }
    return '"' + ($arg -replace '"', '\"') + '"'
}

function Run-NodeToLog([string[]]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'node.exe'
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $exitCode = $p.ExitCode
    $p.Dispose()

    if ($stdout) { [System.IO.File]::AppendAllText($log, $stdout, $utf8) }
    if ($stderr) { [System.IO.File]::AppendAllText($log, $stderr, $utf8) }
    return $exitCode
}

try {
    Add-LogLine "[$(Get-Date -Format s)] Inicio búsqueda"
    $code = Run-NodeToLog @((Join-Path $PSScriptRoot 'search_x.js'))
    if ($code -ne 0) { throw "search_x.js terminó con código $code" }

    $code = Run-NodeToLog @((Join-Path $PSScriptRoot 'telegram_local.js'), 'send')
    if ($code -ne 0) { throw "telegram_local.js send terminó con código $code" }

    Add-LogLine "[$(Get-Date -Format s)] Fin correcto"
}
catch {
    Add-LogLine "[$(Get-Date -Format s)] ERROR: $($_.Exception.Message)"
    exit 1
}
