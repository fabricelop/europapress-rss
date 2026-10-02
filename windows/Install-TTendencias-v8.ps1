# Install-TTendencias-v8.ps1
# Instala/reinstala SOLO el listener dedicado de TTendencias.
# No detiene ni modifica el listener compartido ni las tareas de TTiTTulares.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTendencias Mobile Trigger Listener.cmd"
$RawUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/48778627ec7acc05db9e7cc81fc4043863d59ae9/windows/TTendenciasDedicatedListener.ps1"
$Bridge = Join-Path $BaseDir "TTendenciasImageBridge.js"
$BridgeUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/48778627ec7acc05db9e7cc81fc4043863d59ae9/windows/TTendenciasImageBridge.js"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri ($RawUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Listener -UseBasicParsing
Invoke-WebRequest -Uri ($BridgeUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $Bridge -UseBasicParsing

# Validar sintaxis y garantías v8 antes de reiniciar nada.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  Write-Host "ERROR DE SINTAXIS EN LISTENER TTENDENCIAS" -ForegroundColor Red
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener dedicado descargado no es ejecutable."
}

$listenerText = Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
foreach ($needle in @(
  '$WorkerId = "ttendencias-dedicated-v8"',
  'ArgumentList @($Runner,"tendencias","--enviar")',
  'CHAT LAUNCH MODE ERROR',
  'PROCESS STARTED direct-node-real',
  'RedirectStandardOutput $launchLog',
  'MODO:\s*ENVIO REAL'
)) {
  if (-not $listenerText.Contains($needle)) { throw "Falta garantía TTendencias v8: $needle" }
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe para validar el puente de imagen." }
& $node.Source --check $Bridge
if ($LASTEXITCODE -ne 0) { throw "TTendenciasImageBridge.js no supera node --check." }

$bridgeText = Get-Content -LiteralPath $Bridge -Raw -Encoding UTF8
foreach ($needle in @(
  'BASE_CDP="http://127.0.0.1:9223"',
  'task:"image_upload"',
  'stage:"done"',
  'TT_IMAGE_UPLOAD_SECRET'
)) {
  if (-not $bridgeText.Contains($needle)) { throw "Falta garantía puente TTendencias v8: $needle" }
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

Write-Host "TTENDENCIAS V8 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $($proc.Id)"
Write-Host "Listener: $Listener"
Write-Host "Puente imagen: $Bridge"
Write-Host "Inicio con Windows: $StartupCmd"
Write-Host "Log: C:\TTiTTulares\ttendencias-mobile-trigger.log"
Write-Host "Modo editorial: node Ejecutar.js tendencias --enviar`r`nNo se ha detenido ni modificado TTiTTulares."
Write-Host ""
Write-Host "--- DIAGNOSTICO TTENDENCIAS ---" -ForegroundColor Cyan
if (Test-Path (Join-Path $BaseDir "ttendencias-mobile-trigger.log")) {
  Get-Content (Join-Path $BaseDir "ttendencias-mobile-trigger.log") -Tail 12
}
if ((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0) {
  Write-Host "--- STDERR ---" -ForegroundColor Yellow
  Get-Content $StdErr -Tail 20
}
