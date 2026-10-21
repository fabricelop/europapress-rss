# Install-TTendencias-v11.ps1
# Instala/reinstala SOLO el listener dedicado de TTendencias.
# No detiene ni modifica el listener compartido ni las tareas de TTiTTulares.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTendencias Mobile Trigger Listener.cmd"
$Bridge = Join-Path $BaseDir "TTendenciasImageBridge.js"

function Get-GitHubMainFile([string]$RepoPath,[string]$OutFile) {
  $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + $RepoPath + "?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "TTendencias-v11-installer"
    "Cache-Control" = "no-cache"
  }
  $doc = Invoke-RestMethod -Uri $api -Headers $headers -Method Get -UseBasicParsing
  if (-not $doc.content) { throw "GitHub API no devolvió contenido para $RepoPath" }
  $raw = [Convert]::FromBase64String(([string]$doc.content -replace "\s",""))
  [IO.File]::WriteAllBytes($OutFile,$raw)
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Get-GitHubMainFile "windows/TTendenciasDedicatedListener.ps1" $Listener
Get-GitHubMainFile "windows/TTendenciasImageBridge.js" $Bridge

# Validar sintaxis y garantías v11 antes de reiniciar nada.
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
  '$WorkerId = "ttendencias-dedicated-v11"',
  'ArgumentList @($Runner,"tendencias","--enviar")',
  'CHAT LAUNCH MODE ERROR',
  'PROCESS STARTED direct-node-real',
  'TTENDENCIAS_EDITORIAL_JOB_V2',
  'Build-EditorialMessage',
  'RedirectStandardOutput $launchLog',
  'MODO:\s*ENVIO REAL',
  'Ensure-ImageBridgeLatest',
  'IMAGE BRIDGE REFRESHED',
  'view=image-index&strong=1',
  'view=image-job&strong=1&id='
)) {
  if (-not $listenerText.Contains($needle)) { throw "Falta garantía TTendencias v11: $needle" }
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
  'TT_IMAGE_UPLOAD_SECRET',
  'BRIDGE_MODE="capture-only-v9"',
  'BRIDGE CHAT FOUND mode=',
  'imagesAfterMarker',
  'view=image-job&strong=1&id='
)) {
  if (-not $bridgeText.Contains($needle)) { throw "Falta garantía puente TTendencias v11: $needle" }
}

if (-not (Test-Path (Join-Path $BaseDir "LanzarOculto.vbs"))) {
  throw "No se encuentra C:\TTiTTulares\LanzarOculto.vbs. No se ha tocado TTiTTulares."
}

$cmd = '@echo off' + [Environment]::NewLine +
  'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Listener + '"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

# Eliminar de forma robusta cualquier listener TTendencias antiguo.
for ($round = 1; $round -le 3; $round++) {
  Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
      ($_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or $_.CommandLine -like "*TTendenciasMobileChatTriggerListener.ps1*")
    } |
    ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
  Start-Sleep -Milliseconds 600
}

$remainingOld = @(
  Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
      ($_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or $_.CommandLine -like "*TTendenciasMobileChatTriggerListener.ps1*")
    }
)
if ($remainingOld.Count -gt 0) {
  throw "No se pudieron detener todos los listeners TTendencias antiguos: $($remainingOld.ProcessId -join ', ')"
}

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

# Garantía final: debe quedar exactamente un listener TTendencias.
$live = @(
  Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
      ($_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or $_.CommandLine -like "*TTendenciasMobileChatTriggerListener.ps1*")
    }
)
if ($live.Count -gt 1) {
  $keep = $live | Sort-Object CreationDate -Descending | Select-Object -First 1
  $extras = @($live | Where-Object { $_.ProcessId -ne $keep.ProcessId })
  foreach ($x in $extras) {
    try { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
  }
  if ($extras.Count -gt 0) { Start-Sleep -Milliseconds 700 }
  $live = @(
    Get-CimInstance Win32_Process |
      Where-Object {
        ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
        ($_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or $_.CommandLine -like "*TTendenciasMobileChatTriggerListener.ps1*")
      }
  )
}
if ($live.Count -ne 1) {
  throw "Garantía listener único fallida. PIDs TTendencias: $($live.ProcessId -join ', ')"
}
$listenerPid=[int]$live[0].ProcessId

Write-Host "TTENDENCIAS V11 ACTUALIZADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $listenerPid"
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
