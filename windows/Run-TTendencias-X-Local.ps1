#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot = 'C:\TTiTTulares',[switch]$CheckOnly)
# Independent TTendencias X collector: never edits other projects or the Git worktree.
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 otherwise decodes git stdout using OEM codepage,
# corrupting accents in trend names and evidence provenance.
$utf8Console = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8Console
$OutputEncoding = $utf8Console
$root = [IO.Path]::GetFullPath($RepoRoot)
$workDir = Join-Path $root 'TT-XContext'
$gitRoot = Join-Path $workDir 'git-store'
$sampler = Join-Path $workDir 'x_context.js'
$publisher = Join-Path $workDir 'publish_x_context.js'
$evidence = Join-Path $workDir 'local-evidence.json'
$queueFile = Join-Path $workDir 'queue-snapshot.json'
$log = Join-Path $workDir 'run.log'
$lockFile = Join-Path $workDir 'run.lock'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Note([string]$s) {
  $message = '[' + (Get-Date -Format o) + '] TT_X_WINDOWS ' + $s
  if (-not $CheckOnly) { [IO.File]::AppendAllText($log, $message + [Environment]::NewLine, $utf8) }
  Write-Host $message
}
function GitOutput([string[]]$gitArgs) {
  $r = & git.exe -C $gitRoot @gitArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw ('git failed: ' + ($gitArgs -join ' ')) }
  return ($r -join "`n")
}
if (-not (Test-Path (Join-Path $gitRoot '.git'))) { throw 'TT-XContext isolated Git store missing: install with the corrected installer' }
$node = (Get-Command node.exe -ErrorAction Stop).Source
if (-not (Test-Path $sampler) -or -not (Test-Path $publisher)) { throw 'TT-XContext code missing; install first' }
$env:NODE_PATH = (Join-Path $workDir 'node_modules')
$env:TT_X_GIT_REPO = $gitRoot
if ($CheckOnly) {
  Note 'CHECK_ONLY no X, no remote Git, no task change'
  & $node --check $sampler; if ($LASTEXITCODE -ne 0) { throw 'X sampler syntax invalid' }
  & $node --check $publisher; if ($LASTEXITCODE -ne 0) { throw 'X publisher syntax invalid' }
  $playwrightCheck = Join-Path $workDir 'check_x_playwright.cjs'
  if (-not (Test-Path -LiteralPath $playwrightCheck)) { throw 'Playwright preflight module missing; rerun installer' }
  & $node $playwrightCheck
  if ($LASTEXITCODE -ne 0) { throw 'Playwright not available locally' }
  Note ('X_CREDENTIALS ' + $(if ([Environment]::GetEnvironmentVariable('X_AUTH_TOKEN','User') -and [Environment]::GetEnvironmentVariable('X_CT0','User')){'configured'}else{'missing'}))
  exit 0
}
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$handle = $null
try {
  try { $handle = [IO.File]::Open($lockFile,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch [IO.IOException] { Note 'SKIP another TT X process is already active'; exit 0 }
  Note 'START'
  $env:X_AUTH_TOKEN = [Environment]::GetEnvironmentVariable('X_AUTH_TOKEN','User')
  $env:X_CT0 = [Environment]::GetEnvironmentVariable('X_CT0','User')
  if (-not $env:X_AUTH_TOKEN -or -not $env:X_CT0) { throw 'User X session not configured; ordinary editorial unaffected' }
  GitOutput @('fetch','--quiet','--no-tags','origin','main') | Out-Null
  $queue = GitOutput @('show','refs/remotes/origin/main:trends/editorial-queue.json')
  [IO.File]::WriteAllText($queueFile, $queue + "`n", $utf8)
  # Refresh only this isolated runtime code. Never checkout or reset the shared repo.
  foreach ($entry in @(@('trends/x_context.js',$sampler),@('trends/publish_x_context.js',$publisher))) {
    $src = GitOutput @('show', ('refs/remotes/origin/main:' + $entry[0]))
    $tmpCode = $entry[1] + '.new.js'
    [IO.File]::WriteAllText($tmpCode, $src + "`n", $utf8)
    & $node --check $tmpCode
    if ($LASTEXITCODE -ne 0) { Remove-Item $tmpCode -Force; throw 'Remote X module invalid' }
    Move-Item -LiteralPath $tmpCode -Destination $entry[1] -Force
  }
  $env:TT_X_QUEUE_FILE = $queueFile
  $env:TT_X_OUTPUT_FILE = $evidence
  $env:TT_X_EXECUTION_MODE = 'windows'
  $planText = & $node $sampler --plan 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'X research plan failed' }
  $count = @((($planText -join "`n") | ConvertFrom-Json).targets).Count
  Note ('TARGETS=' + $count)
  if ($count -gt 0) {
    & $node $sampler 2>&1 | ForEach-Object { Note ([string]$_) }
    if ($LASTEXITCODE -ne 0) { throw 'Browser collection failed; editorial unaffected' }
  }
  if (Test-Path $evidence) {
    & $node $publisher $evidence 2>&1 | ForEach-Object { Note ([string]$_) }
    if ($LASTEXITCODE -ne 0) { throw 'Publishing failed; evidence retained locally for retry' }
  }
  Note 'DONE'
} catch {
  Note ('ERROR ' + $_.Exception.Message)
  exit 1
} finally {
  if ($handle) { $handle.Dispose() }
  Remove-Item Env:TT_X_QUEUE_FILE,Env:TT_X_OUTPUT_FILE,Env:TT_X_EXECUTION_MODE,Env:TT_X_GIT_REPO -ErrorAction SilentlyContinue
  Remove-Item Env:X_AUTH_TOKEN,Env:X_CT0 -ErrorAction SilentlyContinue
}
