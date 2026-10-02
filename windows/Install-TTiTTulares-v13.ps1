# Install-TTiTTulares-v13.ps1
# Instalador cerrado y versionado SOLO para TTiTTulares v13.
# No detiene ni modifica TTendencias.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"

# Listener fijado a un commit conocido para evitar caché/mezcla de versiones.
$ListenerUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/589d18cd258d879ec02146abafdbbc4eae440bf4/windows/TTiTTularesDedicatedListener.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri $ListenerUrl -OutFile $Listener -UseBasicParsing

# 1) Validar sintaxis y versión exacta.
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener TTiTTulares v13 descargado tiene errores de sintaxis."
}

$listenerText = Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
if (-not $listenerText.Contains('$WorkerId = "ttittulares-dedicated-v13"')) {
  throw "El listener descargado no es TTiTTulares v13."
}
if (-not $listenerText.Contains('RedirectStandardOutput') -or -not $listenerText.Contains('ttittulares-launch-')) {
  throw "El listener v13 no contiene el log dedicado por ejecución."
}
if (-not $listenerText.Contains('TTendencias unchanged')) {
  throw "El listener v13 no contiene la protección de TTendencias."
}

$Runner = Join-Path $BaseDir "Ejecutar.js"
if (-not (Test-Path -LiteralPath $Runner)) {
  throw "No se encuentra C:\TTiTTulares\Ejecutar.js."
}

# 2) Validar Ejecutar.js SIN modificarlo.
$runnerText = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
$expectedTitulares = 'titulares: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTiTTulares")'
$expectedTendencias = 'tendencias: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTendencias")'
if (-not $runnerText.Contains($expectedTitulares)) {
  throw "Ejecutar.js no tiene habilitado TT_CHAT_MESSAGE_B64 para titulares. No se modifica nada."
}
if (-not $runnerText.Contains($expectedTendencias)) {
  throw "Protección TTendencias: su entrada esperada no coincide. No se modifica nada."
}
if (-not $runnerText.Contains("TT_RESPONSE_CONFIRM_V2")) {
  throw "Ejecutar.js no contiene TT_RESPONSE_CONFIRM_V2. No se modifica nada."
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe." }

& $node.Source --check $Runner
if ($LASTEXITCODE -ne 0) { throw "Ejecutar.js no supera node --check." }

# 3) Startup SOLO de TTiTTulares.
$cmd = '@echo off' + [Environment]::NewLine +
  'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

# 4) Exclusividad SOLO TTiTTulares. TTendencias queda fuera por nombre.
function Get-TTiTTularesListeners {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object {
      $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or
      $_.CommandLine -like "*TTiTTularesMobileChatTriggerListener.ps1*"
    })
}

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

$proc = Start-Process -FilePath "powershell.exe" -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener
) -WindowStyle Hidden -PassThru

Start-Sleep -Seconds 4

# No confiar en el PID devuelto por Start-Process: en algunos arranques
# el proceso visible por CIM puede tener otro PID. La autoridad es:
# 1) exactamente un listener TTiTTulares; 2) ese PID anuncia worker v13
# en las líneas NUEVAS del log de esta instalación.
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

if ($newLog -notmatch ("LISTENER START worker=ttittulares-dedicated-v13 pid=" + [regex]::Escape([string]$activePid))) {
  try { Stop-Process -Id $activePid -Force -ErrorAction SilentlyContinue } catch {}
  throw "Hay un único listener TTiTTulares (PID $activePid), pero no confirmó worker v13 en el log nuevo."
}

Write-Host "TTITTULARES V13 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $activePid"
Write-Host "Listener fijado a commit: 589d18cd258d879ec02146abafdbbc4eae440bf4"
Write-Host "TTendencias: NO MODIFICADO" -ForegroundColor Green
Write-Host "Ejecutar.js: validado, NO MODIFICADO" -ForegroundColor Green
Write-Host "Log: $log"
