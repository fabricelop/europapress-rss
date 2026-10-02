# Install-TTiTTulares-v14.ps1
# Instalador inmutable SOLO para TTiTTulares v14.
# No modifica TTendencias ni Ejecutar.js.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"
$ListenerUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/030e4277e89d12d0c7c158c86ca97779cd2f64b4/windows/TTiTTularesDedicatedListener.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri $ListenerUrl -OutFile $Listener -UseBasicParsing

# Validar sintaxis y versión exacta del listener.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener TTiTTulares v14 descargado tiene errores de sintaxis."
}

$listenerText = Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
foreach ($needle in @(
  '$WorkerId = "ttittulares-dedicated-v14"',
  'ArgumentList @($Runner,"titulares","--enviar")',
  'EDITORIAL PROCESS STARTED direct-node-real',
  'MODO:\s*ENVIO REAL',
  'RedirectStandardOutput',
  'ttittulares-launch-'
)) {
  if (-not $listenerText.Contains($needle)) {
    throw "El listener descargado no contiene la garantía v14 esperada: $needle"
  }
}

# Validar Ejecutar.js SIN modificarlo.
$Runner = Join-Path $BaseDir "Ejecutar.js"
if (-not (Test-Path -LiteralPath $Runner)) {
  throw "No se encuentra C:\TTiTTulares\Ejecutar.js."
}

$runnerText = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
foreach ($needle in @(
  'const enviar = process.argv.includes("--enviar");',
  'titulares: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTiTTulares")',
  'tendencias: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTendencias")',
  'TT_RESPONSE_CONFIRM_V2'
)) {
  if (-not $runnerText.Contains($needle)) {
    throw "Ejecutar.js no contiene la garantía esperada: $needle. No se modifica nada."
  }
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe." }
& $node.Source --check $Runner
if ($LASTEXITCODE -ne 0) { throw "Ejecutar.js no supera node --check." }

# Startup SOLO de TTiTTulares.
$cmd = '@echo off' + [Environment]::NewLine +
  'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

function Get-TTiTTularesListeners {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object {
      $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or
      $_.CommandLine -like "*TTiTTularesMobileChatTriggerListener.ps1*"
    })
}

# Cerrar SOLO listeners TTiTTulares previos.
Get-TTiTTularesListeners | ForEach-Object {
  try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
}

$deadline = (Get-Date).AddSeconds(6)
do {
  Start-Sleep -Milliseconds 250
  $remaining = Get-TTiTTularesListeners
} while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

if ($remaining.Count -gt 0) {
  throw ("No se pudieron cerrar listeners TTiTTulares anteriores: " + (($remaining | ForEach-Object ProcessId) -join ","))
}

$log = Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$logOffset = 0L
if (Test-Path -LiteralPath $log) {
  try { $logOffset = (Get-Item -LiteralPath $log).Length } catch {}
}

Start-Process -FilePath "powershell.exe" -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener
) -WindowStyle Hidden | Out-Null

Start-Sleep -Seconds 4

$active = @(Get-TTiTTularesListeners)
if ($active.Count -ne 1) {
  $ids = ($active | ForEach-Object { $_.ProcessId }) -join ","
  throw "Exclusividad TTiTTulares fallida: se esperaba 1 listener y se ven $($active.Count). PIDs: $ids"
}

$activePid = [int]$active[0].ProcessId
$newLog = ""
if (Test-Path -LiteralPath $log) {
  try {
    $fs = [System.IO.File]::Open($log,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try {
      if ($logOffset -gt $fs.Length) { $logOffset = 0 }
      [void]$fs.Seek($logOffset,[System.IO.SeekOrigin]::Begin)
      $sr = New-Object System.IO.StreamReader($fs,[System.Text.Encoding]::UTF8,$true,4096,$true)
      try { $newLog = $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
  } catch {}
}

if ($newLog -notmatch ("LISTENER START worker=ttittulares-dedicated-v14 pid=" + [regex]::Escape([string]$activePid))) {
  try { Stop-Process -Id $activePid -Force -ErrorAction SilentlyContinue } catch {}
  throw "Hay un único listener TTiTTulares (PID $activePid), pero no confirmó worker v14 en el log nuevo."
}

Write-Host "TTITTULARES V14 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $activePid"
Write-Host "Listener fijado a commit: 030e4277e89d12d0c7c158c86ca97779cd2f64b4"
Write-Host "Invocación editorial: node Ejecutar.js titulares --enviar" -ForegroundColor Green
Write-Host "TTendencias: NO MODIFICADO" -ForegroundColor Green
Write-Host "Ejecutar.js: validado, NO MODIFICADO" -ForegroundColor Green
Write-Host "Log: $log"
