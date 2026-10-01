# Install-MobileChatTrigger.ps1
# Instala el listener móvil -> PC sin tocar las programaciones actuales.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "MobileChatTriggerListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TT Mobile Trigger Listener.cmd"
$RawUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/MobileChatTriggerListener.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri ($RawUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Listener -UseBasicParsing

# Validar sintaxis ANTES de matar el listener anterior.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  Write-Host "ERROR DE SINTAXIS EN LISTENER" -ForegroundColor Red
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener descargado no es ejecutable."
}

if (-not (Test-Path (Join-Path $BaseDir "LanzarOculto.vbs"))) {
  throw "No se encuentra C:\TTiTTulares\LanzarOculto.vbs. No se ha cambiado ninguna programación."
}

$cmd = '@echo off' + [Environment]::NewLine + 'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like "*MobileChatTriggerListener.ps1*" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

$StdOut = Join-Path $BaseDir "mobile-trigger-stdout.log"
$StdErr = Join-Path $BaseDir "mobile-trigger-stderr.log"
Remove-Item $StdOut,$StdErr -Force -ErrorAction SilentlyContinue

$proc = Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener) -WindowStyle Hidden -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru
Start-Sleep -Seconds 4
$proc.Refresh()

if ($proc.HasExited) {
  Write-Host "ERROR: el listener se ha cerrado al arrancar. ExitCode=$($proc.ExitCode)" -ForegroundColor Red
  if (Test-Path $StdErr) {
    Write-Host "--- STDERR ---" -ForegroundColor Yellow
    Get-Content $StdErr -Tail 30
  }
  if (Test-Path (Join-Path $BaseDir "mobile-trigger.log")) {
    Write-Host "--- ULTIMO LOG ---" -ForegroundColor Yellow
    Get-Content (Join-Path $BaseDir "mobile-trigger.log") -Tail 20
  }
  throw "El listener no ha quedado activo."
}

Write-Host "INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $($proc.Id)"
Write-Host "Listener: $Listener"
Write-Host "Inicio con Windows: $StartupCmd"
Write-Host "Log: C:\TTiTTulares\mobile-trigger.log"
Write-Host "Las tareas TTiTTulares Local y TTendencias Local NO se han modificado."
Write-Host ""
Write-Host "--- DIAGNOSTICO DE ARRANQUE ---" -ForegroundColor Cyan
if (Test-Path (Join-Path $BaseDir "mobile-trigger.log")) {
  Get-Content (Join-Path $BaseDir "mobile-trigger.log") -Tail 12
}
if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
  Write-Host "--- STDERR ---" -ForegroundColor Yellow
  Get-Content $StdErr -Tail 20
}
