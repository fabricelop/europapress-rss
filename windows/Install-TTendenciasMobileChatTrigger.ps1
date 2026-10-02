# Install-TTendenciasMobileChatTrigger.ps1
# Instala/reinstala SOLO el listener dedicado de TTendencias.
# No detiene ni modifica el listener compartido ni las tareas de TTiTTulares.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTendencias Mobile Trigger Listener.cmd"
$RawUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/TTendenciasDedicatedListener.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri ($RawUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Listener -UseBasicParsing

Write-Host "RESTAURANDO EJECUTAR.JS CONOCIDO-BUENO PARA ENTRADAS" -ForegroundColor Cyan
$Runner = Join-Path $BaseDir "Ejecutar.js"
$KnownGoodExact = Join-Path $BaseDir "Ejecutar.js.before-ttendencias-image-chat-20261002_011820.bak"
$KnownGood = $null

if (Test-Path -LiteralPath $KnownGoodExact) {
  $KnownGood = $KnownGoodExact
} else {
  $KnownGood = Get-ChildItem -LiteralPath $BaseDir -Filter "Ejecutar.js.before-ttendencias-image-chat-*.bak" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime |
    Select-Object -First 1 -ExpandProperty FullName
}

if (-not $KnownGood -or -not (Test-Path -LiteralPath $KnownGood)) {
  throw "No se encontró el backup conocido-bueno de Ejecutar.js anterior a imágenes."
}

if (Test-Path -LiteralPath $Runner) {
  $safetyBackup = $Runner + ".before-editorial-restore-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
  Copy-Item -LiteralPath $Runner -Destination $safetyBackup -Force
  Write-Host "Backup de seguridad actual: $safetyBackup"
}

Copy-Item -LiteralPath $KnownGood -Destination $Runner -Force

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe para validar Ejecutar.js" }

& $node.Source --check $Runner
if ($LASTEXITCODE -ne 0) {
  throw "El Ejecutar.js restaurado no supera node --check."
}

Write-Host "EJECUTAR.JS RESTAURADO Y VALIDADO" -ForegroundColor Green
Write-Host "Origen conocido-bueno: $KnownGood"



# Validar sintaxis antes de reiniciar nada.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  Write-Host "ERROR DE SINTAXIS EN LISTENER TTENDENCIAS" -ForegroundColor Red
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener dedicado descargado no es ejecutable."
}

if (-not (Test-Path (Join-Path $BaseDir "LanzarOculto.vbs"))) {
  throw "No se encuentra C:\TTiTTulares\LanzarOculto.vbs. No se ha tocado TTiTTulares."
}

$cmd = '@echo off' + [Environment]::NewLine +
  'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

# Solo mata una instancia anterior DEL LISTENER DEDICADO.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or $_.CommandLine -like "*TTendenciasMobileChatTriggerListener.ps1*" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

$StdOut = Join-Path $BaseDir "ttendencias-dedicated-stdout.log"
$StdErr = Join-Path $BaseDir "ttendencias-dedicated-stderr.log"
Remove-Item $StdOut,$StdErr -Force -ErrorAction SilentlyContinue

$proc = Start-Process powershell.exe -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener
) -WindowStyle Hidden -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru

Start-Sleep -Seconds 4
$proc.Refresh()
if ($proc.HasExited) {
  Write-Host "ERROR: listener dedicado TTendencias cerrado al arrancar. ExitCode=$($proc.ExitCode)" -ForegroundColor Red
  if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
    Write-Host "--- STDERR ---" -ForegroundColor Yellow
    Get-Content $StdErr -Tail 30
  }
  throw "El listener dedicado no ha quedado activo."
}

Write-Host "TTENDENCIAS LISTENER INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $($proc.Id)"
Write-Host "Listener: $Listener"
Write-Host "Inicio con Windows: $StartupCmd"
Write-Host "Log: C:\TTiTTulares\ttendencias-mobile-trigger.log"
Write-Host "No se ha detenido ni modificado el listener compartido ni TTiTTulares."
Write-Host ""
Write-Host "--- DIAGNOSTICO TTENDENCIAS ---" -ForegroundColor Cyan
if (Test-Path (Join-Path $BaseDir "ttendencias-mobile-trigger.log")) {
  Get-Content (Join-Path $BaseDir "ttendencias-mobile-trigger.log") -Tail 12
}
if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
  Write-Host "--- STDERR ---" -ForegroundColor Yellow
  Get-Content $StdErr -Tail 20
}
