# Install-ImageBridge-Hotfix.ps1
# Actualiza SOLO listeners/bridges de imagen para TTendencias y TTiTTulares.
# No modifica Ejecutar.js ni la lógica editorial.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"

function Get-MainFile([string]$RepoPath,[string]$OutFile) {
  # Leer directamente del CDN raw público evita consumir la cuota REST de GitHub.
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rawUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" + $RepoPath + "?t=" + $stamp
  Invoke-WebRequest -Uri $rawUrl -OutFile $OutFile -Headers @{
    "User-Agent" = "TT-image-hotfix"
    "Cache-Control" = "no-cache"
  } -TimeoutSec 30 -UseBasicParsing
  if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 100) {
    throw "Descarga raw inválida para $RepoPath"
  }
}

function Validate-PowerShell([string]$File,[string[]]$Needles) {
  $tokens=$null;$errs=$null
  [System.Management.Automation.Language.Parser]::ParseFile($File,[ref]$tokens,[ref]$errs)|Out-Null
  if($errs.Count -gt 0){throw "Error de sintaxis en $File : $($errs[0].Message)"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  foreach($n in $Needles){if(-not $txt.Contains($n)){throw "Falta garantía '$n' en $File"}}
}

function Validate-Node([string]$File,[string[]]$Needles) {
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  $oldEap=$ErrorActionPreference
  try {
    $ErrorActionPreference="Continue"
    & $node.Source --check $File 1>$null 2>$null
    $nodeCode=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$oldEap
  }
  if($nodeCode -ne 0){throw "node --check falló en $File"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  foreach($n in $Needles){if(-not $txt.Contains($n)){throw "Falta garantía '$n' en $File"}}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$trendListener = Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$trendBridge   = Join-Path $BaseDir "TTendenciasImageBridge.js"
$titleListener= Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$titleBridge  = Join-Path $BaseDir "TTiTTularesImageBridge.js"

$tmpTrendListener=$trendListener+".new"
$tmpTrendBridge=Join-Path $BaseDir "TTendenciasImageBridge.new.js"
$tmpTitleListener=$titleListener+".new"
$tmpTitleBridge=Join-Path $BaseDir "TTiTTularesImageBridge.new.js"

Get-MainFile "windows/TTendenciasDedicatedListener.ps1" $tmpTrendListener
Get-MainFile "windows/TTendenciasImageBridge.js" $tmpTrendBridge
Get-MainFile "windows/TTiTTularesDedicatedListener.ps1" $tmpTitleListener
Get-MainFile "windows/TTiTTularesImageBridge.js" $tmpTitleBridge

Validate-PowerShell $tmpTrendListener @(
  '$WorkerId = "ttendencias-dedicated-',
  'IMAGE CHAT UNCONFIRMED; BRIDGE WILL VERIFY',
  'Start-ImageBridge $commandId $targetId $uploadSecret'
)
Validate-Node $tmpTrendBridge @(
  'BRIDGE_MODE="capture-only-v28-dead-submit-retry"',
  'BRIDGE_FEATURES="v29-visible-composer-trusted-click-dom-fallback"',
  'original-fetch-img',
  'canvas-from-img-'
)
Validate-PowerShell $tmpTitleListener @(
  '$WorkerId = "ttittulares-dedicated-',
  'IMAGE CHAT UNCONFIRMED; BRIDGE WILL VERIFY',
  'Start-ImageBridge $commandId $targetId $uploadSecret'
)
Validate-Node $tmpTitleBridge @(
  'BRIDGE_MODE="capture-only-v28-dead-submit-retry"',
  'BRIDGE_FEATURES="v29-visible-composer-trusted-click-dom-fallback"',
  'BRIDGE_PATCH="v31-rotating-trusted-submit"',
  'original-fetch-img',
  'canvas-from-img-',
  'image-element-screenshot-'
)

# Sustitución atómica tras validación.
Move-Item -LiteralPath $tmpTrendListener -Destination $trendListener -Force
Move-Item -LiteralPath $tmpTrendBridge -Destination $trendBridge -Force
Move-Item -LiteralPath $tmpTitleListener -Destination $titleListener -Force
Move-Item -LiteralPath $tmpTitleBridge -Destination $titleBridge -Force

function Stop-Listener([string]$Pattern) {
  @(Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $Pattern
  }) | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
  }
}

Stop-Listener "*TTendenciasDedicatedListener.ps1*"
Stop-Listener "*TTiTTularesDedicatedListener.ps1*"
Start-Sleep -Milliseconds 800

$trendOut=Join-Path $BaseDir "ttendencias-dedicated-stdout.log"
$trendErr=Join-Path $BaseDir "ttendencias-dedicated-stderr.log"
$titleOut=Join-Path $BaseDir "ttittulares-dedicated-stdout.log"
$titleErr=Join-Path $BaseDir "ttittulares-dedicated-stderr.log"

$trendProc=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$trendListener) -WindowStyle Hidden -RedirectStandardOutput $trendOut -RedirectStandardError $trendErr -PassThru
$titleProc=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$titleListener) -WindowStyle Hidden -RedirectStandardOutput $titleOut -RedirectStandardError $titleErr -PassThru
Start-Sleep -Seconds 4
$trendProc.Refresh();$titleProc.Refresh()
if($trendProc.HasExited){throw "TTendencias listener no quedó activo"}
if($titleProc.HasExited){throw "TTiTTulares listener no quedó activo"}

Write-Host "HOTFIX IMAGEN ACTIVO" -ForegroundColor Green
Write-Host "TTendencias PID: $($trendProc.Id)"
Write-Host "TTiTTulares PID: $($titleProc.Id)"
Write-Host "Bridge: v31 visible-composer + trusted click + DOM/keyboard fallback"
Write-Host "Falso negativo de Ejecutar.js: ya no aborta el job; lo verifica el bridge."
