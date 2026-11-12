#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot = 'C:\TTiTTulares', [switch]$CheckOnly, [switch]$Uninstall, [switch]$NoStart)
# Install ONLY TTendencias-XContext; never stop/reconfigure SeLoRecordamos or other TT tasks.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = [IO.Path]::GetFullPath($RepoRoot)
$workDir = Join-Path $root 'TT-XContext'
$runner = Join-Path $workDir 'Run-TTendencias-X-Local.ps1'
$hiddenLauncher = Join-Path $workDir 'TTendencias-XContext-hidden.vbs'
$taskName = 'TTendencias-XContext'
if ($Uninstall) {
  $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host 'TT_X_UNINSTALLED task only (files preserved)' }
  else { Write-Host 'TT_X_UNINSTALLED task absent' }
  exit 0
}
# C:\TTiTTulares hosts the runtime, not necessarily a Git working tree.
$gitRoot = Join-Path $workDir 'git-store'
$node = (Get-Command node.exe -ErrorAction Stop).Source
if ($CheckOnly) {
  Write-Host 'TT_X_CHECK_ONLY: no installation, no X request'
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    Get-ScheduledTaskInfo -TaskName $taskName | Select-Object LastRunTime,LastTaskResult,NextRunTime
    Write-Host ('TT_X_TASK_ACTION=' + [string]$task.Actions[0].Execute)
  }
  else { Write-Host 'TASK_NOT_INSTALLED' }
  if(Test-Path $runner) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $root -CheckOnly; exit $LASTEXITCODE }
  Write-Host 'RUNNER_NOT_INSTALLED'
  exit 0
}
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
function Download([string]$relative,[string]$destination) {
  $uri = 'https://api.github.com/repos/fabricelop/europapress-rss/contents/' + $relative + '?ref=main&t=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $doc = Invoke-RestMethod -Uri $uri -Headers @{'Accept'='application/vnd.github+json'; 'User-Agent'='TT-X-Windows-Installer'; 'Cache-Control'='no-cache'} -TimeoutSec 35
  if (-not $doc.content) { throw "GitHub file missing: $relative" }
  $bytes = [Convert]::FromBase64String(([string]$doc.content -replace '\s',''))
  $temp = $destination + '.download'
  [IO.File]::WriteAllBytes($temp,$bytes)
  Move-Item -LiteralPath $temp -Destination $destination -Force
}
Download 'windows/Run-TTendencias-X-Local.ps1' $runner
Download 'windows/TTendencias-XContext-hidden.vbs' $hiddenLauncher
Download 'trends/x_context.js' (Join-Path $workDir 'x_context.js')
Download 'trends/publish_x_context.js' (Join-Path $workDir 'publish_x_context.js')
Download 'trends/test_x_context.cjs' (Join-Path $workDir 'test_x_context.cjs')
Download 'trends/check_x_playwright.cjs' (Join-Path $workDir 'check_x_playwright.cjs')
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw 'Invalid runner PowerShell syntax: ' + $errors[0].Message }
foreach ($f in @('x_context.js','publish_x_context.js')) {
  & $node --check (Join-Path $workDir $f)
  if ($LASTEXITCODE -ne 0) { throw "Invalid JS syntax: $f" }
}
if (-not (Test-Path (Join-Path $gitRoot '.git'))) {
  if ((Test-Path $gitRoot) -and @(Get-ChildItem -LiteralPath $gitRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Unexpected nonempty TT-XContext git-store; refusing to overwrite it'
  }
  & git.exe init --quiet $gitRoot
  if ($LASTEXITCODE -ne 0) { throw 'Could not initialize isolated Git store' }
  & git.exe -C $gitRoot remote add origin 'https://github.com/fabricelop/europapress-rss.git'
  if ($LASTEXITCODE -ne 0) { throw 'Could not configure isolated Git origin' }
}
$remoteOrigin = (& git.exe -C $gitRoot remote get-url origin) -join ''
if ($LASTEXITCODE -ne 0 -or $remoteOrigin -notmatch '^https://github[.]com/fabricelop/europapress-rss([.]git)?/?$') {
  throw 'Unexpected isolated Git origin; no other repository will be used'
}
& git.exe -C $gitRoot fetch --quiet --depth=1 origin main
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch main into isolated Git store' }
$env:NODE_PATH = (Join-Path $workDir 'node_modules')
$playwrightCheck = Join-Path $workDir 'check_x_playwright.cjs'
& $node $playwrightCheck
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Installing Playwright package ONLY in TT-XContext...'
  $npm = (Get-Command npm.cmd -ErrorAction Stop).Source
  & $npm install --prefix $workDir --no-save --no-package-lock playwright
  if ($LASTEXITCODE -ne 0) { throw 'Isolated Playwright installation failed; task not installed' }
}
& $node $playwrightCheck
if ($LASTEXITCODE -ne 0) { throw 'Playwright unavailable; task not installed' }
& $node --test (Join-Path $workDir 'test_x_context.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed; task not installed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $root -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Runner preflight failed; task not installed' }
# This is the ONLY task that is created or replaced. wscript.exe is a GUI
# launcher with window style 0; PowerShell -WindowStyle Hidden alone can flash
# a console for a moment before the flag takes effect.
$wasRunning = $false
$currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($currentTask) { $wasRunning = $currentTask.State -eq 'Running' }
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript)) { throw 'Windows Script Host is unavailable; task not changed' }
if (-not (Test-Path -LiteralPath $hiddenLauncher)) { throw 'Invisible task launcher missing; task not changed' }
$command = '"' + $wscript + '" "' + $hiddenLauncher + '"'
& schtasks.exe /Create /TN $taskName /TR $command /SC MINUTE /MO 30 /ST '00:12' /RL LIMITED /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not register TTendencias-XContext task' }
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 12)
Set-ScheduledTask -TaskName $taskName -Settings $settings | Out-Null
Write-Host 'TT_X_WINDOWS_INSTALLED: independent INVISIBLE 30-min scheduled task (wscript.exe)' -ForegroundColor Green
Write-Host ('Log: ' + (Join-Path $workDir 'run.log'))
Write-Host 'No changes to SeLoRecordamos, editorial, images, publishing or Chrome CDP'
if (-not $NoStart) {
  if ($wasRunning) { Write-Host 'TT_X_WINDOWS_RUN_ALREADY_ACTIVE: not launching a duplicate; updated action applies to subsequent runs' }
  else { Start-ScheduledTask -TaskName $taskName; Write-Host 'TT_X_WINDOWS_FIRST_HIDDEN_RUN_REQUESTED: check the log for real X evidence and publication' }
}
