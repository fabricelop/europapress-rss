# Install-TTiTTularesMobileChatTrigger.ps1
# Instala/reinstala SOLO el listener dedicado de TTiTTulares.
# No detiene ni modifica el listener compartido ni las tareas programadas.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"
$RawUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/TTiTTularesDedicatedListener.ps1"
$Patch = Join-Path $BaseDir "Patch-Ejecutar-ConfirmResponse.ps1"
$PatchUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/Patch-Ejecutar-ConfirmResponse.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri ($RawUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Listener -UseBasicParsing

# Validar sintaxis antes de reiniciar nada.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  Write-Host "ERROR DE SINTAXIS EN LISTENER TTITTULARES" -ForegroundColor Red
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener dedicado descargado no es ejecutable."
}

$listenerText = Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
if (-not $listenerText.Contains('$WorkerId = "ttittulares-dedicated-v2"') -or
    -not $listenerText.Contains('PROCESS STARTED direct-node')) {
  throw "La descarga no contiene el listener TTiTTulares dedicado v2 con lanzamiento Node directo."
}

if (-not (Test-Path (Join-Path $BaseDir "LanzarOculto.vbs"))) {
  throw "No se encuentra C:\TTiTTulares\LanzarOculto.vbs. No se ha tocado TTiTTulares."
}

if (-not (Test-Path (Join-Path $BaseDir "Ejecutar.js"))) {
  throw "No se encuentra C:\TTiTTulares\Ejecutar.js. No se puede validar el envío real a ChatGPT."
}

Invoke-WebRequest -Uri ($PatchUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Patch -UseBasicParsing

$patchTokens = $null
$patchParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Patch,[ref]$patchTokens,[ref]$patchParseErrors) | Out-Null
if ($patchParseErrors.Count -gt 0) {
  throw "El parche de Ejecutar.js tiene errores de sintaxis y no se aplicará."
}

& $Patch
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo reforzar Ejecutar.js."
}

$cmd = '@echo off' + [Environment]::NewLine +
  'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

# Solo mata una instancia anterior DEL LISTENER DEDICADO.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or $_.CommandLine -like "*TTiTTularesMobileChatTriggerListener.ps1*" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

$StdOut = Join-Path $BaseDir "ttittulares-dedicated-stdout.log"
$StdErr = Join-Path $BaseDir "ttittulares-dedicated-stderr.log"
Remove-Item $StdOut,$StdErr -Force -ErrorAction SilentlyContinue

$proc = Start-Process powershell.exe -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener
) -WindowStyle Hidden -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru

Start-Sleep -Seconds 4
$proc.Refresh()
if ($proc.HasExited) {
  Write-Host "ERROR: listener dedicado TTiTTulares cerrado al arrancar. ExitCode=$($proc.ExitCode)" -ForegroundColor Red
  if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
    Write-Host "--- STDERR ---" -ForegroundColor Yellow
    Get-Content $StdErr -Tail 30
  }
  throw "El listener dedicado no ha quedado activo."
}

Write-Host "TTITTULARES LISTENER INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $($proc.Id)"
Write-Host "Listener: $Listener"
Write-Host "Inicio con Windows: $StartupCmd"
Write-Host "Log: C:\TTiTTulares\ttittulares-mobile-trigger.log"
Write-Host "Entradas: Node directo + marcador por command_id + confirmación real activados."
Write-Host "No se ha detenido ni modificado el listener compartido ni las tareas programadas."
Write-Host ""
Write-Host "--- DIAGNOSTICO TTITTULARES ---" -ForegroundColor Cyan
if (Test-Path (Join-Path $BaseDir "ttittulares-mobile-trigger.log")) {
  Get-Content (Join-Path $BaseDir "ttittulares-mobile-trigger.log") -Tail 12
}
if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
  Write-Host "--- STDERR ---" -ForegroundColor Yellow
  Get-Content $StdErr -Tail 20
}
