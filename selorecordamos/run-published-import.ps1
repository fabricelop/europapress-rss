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
  $outFile = Join-Path $logDir 'published-import-stdout.log'
  $errFile = Join-Path $logDir 'published-import-stderr.log'
  Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue
  # Start-Process -PassThru on Windows PowerShell 5.1 may leave ExitCode null
  # even after WaitForExit; use the real .NET Process exit code instead.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node.exe'
  $psi.Arguments = '"' + (Join-Path $PSScriptRoot 'import_published.js') + '"'
  $psi.WorkingDirectory = $repo
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $outStream = $null
  $errStream = $null
  $exitCode = $null
  $timedOut = $false
  try {
    [void]$p.Start()
    $outStream = [System.IO.File]::Create($outFile)
    $errStream = [System.IO.File]::Create($errFile)
    # Stream to disk asynchronously to avoid buffering large JSON responses.
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outStream)
    $errTask = $p.StandardError.BaseStream.CopyToAsync($errStream)

    if (-not $p.WaitForExit(900000)) {
      $timedOut = $true
      try { & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null }
      catch { try { $p.Kill() } catch {} }
      [void]$p.WaitForExit(15000)
    }
    if (-not $timedOut) {
      $outTask.GetAwaiter().GetResult()
      $errTask.GetAwaiter().GetResult()
      $exitCode = [int]$p.ExitCode
    }
  } finally {
    if ($outStream) { $outStream.Dispose() }
    if ($errStream) { $errStream.Dispose() }
    $p.Dispose()
  }
  if ($timedOut) { throw 'TIMEOUT import_published.js tras 900 segundos; proceso y descendientes detenidos' }
  if (Test-Path $outFile) { Get-Content $outFile | Add-Content $log }
  if (Test-Path $errFile) {
    $stderr = Get-Content $errFile
    $realErrors = @($stderr | Where-Object { $_ -and $_ -notmatch '^warning: in the working copy of .*LF will be replaced by CRLF' -and $_ -notmatch '^the next time Git touches it' })
    if ($realErrors.Count -gt 0) { $realErrors | Add-Content $log }
  }
  if ($exitCode -ne 0) { throw "import_published.js termino con codigo $exitCode" }
  "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] Fin correcto" | Add-Content $log
} catch {
  "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] ERROR: $($_.Exception.Message)" | Add-Content $log
  exit 1
}
