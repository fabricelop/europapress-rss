$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ("tt-instance-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null
$engine = (Get-Process -Id $PID).Path
try {
  foreach ($file in @("TTiTTularesDedicatedListener.ps1", "TTendenciasDedicatedListener.ps1", "TT-LocalWatchdog.ps1")) {
    $source = Get-Content (Join-Path $root ("windows/" + $file)) -Raw
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse failed: $file" }
    $fn = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Enter-ProcessInstance"}, $true) | Select-Object -First 1
    if (-not $fn) { throw "Missing process ownership: $file" }
    Invoke-Expression $fn.Extent.Text
    $lockPath = Join-Path $temp ($file + ".lock")
    $readyPath = Join-Path $temp ($file + ".ready")
    $childPath = Join-Path $temp ($file + ".child.ps1")
    $childSource = $fn.Extent.Text + @'

if (-not (Enter-ProcessInstance $args[0])) { exit 7 }
Set-Content -LiteralPath $args[1] -Value "ready"
Start-Sleep -Seconds 60
'@
    Set-Content -LiteralPath $childPath -Value $childSource -Encoding UTF8
    $child = Start-Process -FilePath $engine -ArgumentList @("-NoProfile", "-File", ('"' + $childPath + '"'), ('"' + $lockPath + '"'), ('"' + $readyPath + '"')) -PassThru
    try {
      $deadline = (Get-Date).AddSeconds(15)
      while (-not (Test-Path $readyPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
      if (-not (Test-Path $readyPath)) { throw "Owner did not start: $file" }
      if (Enter-ProcessInstance $lockPath) { throw "Two processes own the same state: $file" }
      Stop-Process -Id $child.Id -Force
      $child.WaitForExit()
      if (-not (Test-Path $lockPath)) { throw "Test requires a retained lock file" }
      if (-not (Enter-ProcessInstance $lockPath)) { throw "Crashed owner prevents recovery: $file" }
      $script:InstanceHandle.Dispose()
      $script:InstanceHandle = $null
      Write-Host "PASS: exclusive owner and recovery after process termination: $file"
    } finally {
      if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
    }
  }
  # An unrelated task must not replace a running listener just because it is newer.
  $source = Get-Content (Join-Path $root "windows/TT-LocalWatchdog.ps1") -Raw
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  $fn = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "EnsureSingle"}, $true) | Select-Object -First 1
  Invoke-Expression $fn.Extent.Text
  function PsProcs { @([pscustomobject]@{ProcessId=111;CreationDate=[datetime]"2026-10-09T11:00:00"},[pscustomobject]@{ProcessId=222;CreationDate=[datetime]"2026-10-09T11:01:00"}) }
  $script:stopped = @()
  function Stop-Process { param($Id,[switch]$Force,$ErrorAction) $script:stopped += $Id }
  function Log { param($Text) }
  EnsureSingle "test" "test.ps1" "test"
  if ($script:stopped.Count -ne 1 -or $script:stopped[0] -ne 222) { throw "Dedup replaced the older owner" }
  Write-Host "PASS: dedup preserves the running owner"
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
