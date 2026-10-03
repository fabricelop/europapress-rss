# Install-TTiTTulares-v18.ps1
# Instala/reinstala SOLO el listener dedicado de TTiTTulares + bridge manual de Gag IA.
# No detiene ni modifica TTendencias.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Bridge = Join-Path $BaseDir "TTiTTularesImageBridge.js"
$Runner = Join-Path $BaseDir "Ejecutar.js"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"

function Get-GitHubMainFile([string]$RepoPath,[string]$OutFile) {
  $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + $RepoPath + "?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "TTiTTulares-v18-installer"
    "Cache-Control" = "no-cache"
  }
  $doc = Invoke-RestMethod -Uri $api -Headers $headers -Method Get -UseBasicParsing
  if (-not $doc.content) { throw "GitHub API no devolvió contenido para $RepoPath" }
  $raw = [Convert]::FromBase64String(([string]$doc.content -replace "\s",""))
  [IO.File]::WriteAllBytes($OutFile,$raw)
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Get-GitHubMainFile "windows/TTiTTularesDedicatedListener.ps1" $Listener
Get-GitHubMainFile "windows/TTiTTularesImageBridge.js" $Bridge

# Validar sintaxis PowerShell y garantías editoriales + visuales.
$tokens=$null;$parseErrors=$null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors)|Out-Null
if($parseErrors.Count -gt 0){
  Write-Host "ERROR DE SINTAXIS EN LISTENER TTITTULARES" -ForegroundColor Red
  $parseErrors | ForEach-Object { Write-Host ("  " + $_.Message + " @ " + $_.Extent.StartLineNumber) -ForegroundColor Red }
  throw "El listener v18 descargado no es ejecutable."
}

$listenerText=Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
foreach($needle in @(
  '$WorkerId = "ttittulares-dedicated-v18"',
  'ArgumentList @($Runner,"titulares","--enviar")',
  'Remove-Item Env:TT_CHAT_MESSAGE_B64',
  'Mensaje preparado:\s*Ejecuta TTiTTulares',
  'EDITORIAL PROCESS STARTED direct-node-real-explicit-message',
  'TTITTULARES_EDITORIAL_JOB_V2',
  'Build-EditorialMessage',
  '$MaxParallelImageChats = 1',
  'view=image-index&strong=1',
  'view=image-job&strong=1&id=',
  'Launch-ImageChat',
  'Ensure-ImageBridgeLatest',
  'TTITTULARES_IMAGE_JOB_V3'
)){
  if(-not $listenerText.Contains($needle)){throw "Falta garantía TTiTTulares v18: $needle"}
}

if(-not (Test-Path -LiteralPath $Runner)){throw "No se encuentra C:\TTiTTulares\Ejecutar.js."}
$runnerText=Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
foreach($needle in @(
  'const enviar = process.argv.includes("--enviar");',
  'titulares: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTiTTulares")',
  'tendencias: (process.env.TT_CHAT_MESSAGE_B64 ? Buffer.from(process.env.TT_CHAT_MESSAGE_B64,"base64").toString("utf8") : "Ejecuta TTendencias")'
)){
  if(-not $runnerText.Contains($needle)){throw "Ejecutar.js no coincide con la garantía esperada: $needle"}
}

$node=Get-Command node.exe -ErrorAction SilentlyContinue
if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
if(-not $node){throw "No encuentro node.exe."}

& $node.Source --check $Runner
if($LASTEXITCODE -ne 0){throw "Ejecutar.js no supera node --check."}
& $node.Source --check $Bridge
if($LASTEXITCODE -ne 0){throw "TTiTTularesImageBridge.js no supera node --check."}

$bridgeText=Get-Content -LiteralPath $Bridge -Raw -Encoding UTF8
foreach($needle in @(
  'BASE_CDP="http://127.0.0.1:9223"',
  'BRIDGE_MODE="capture-only',
  'ttittulares-run-status?view=image-job&strong=1&id=',
  'task:"image_upload"',
  'stage:"done"',
  'TT_IMAGE_UPLOAD_SECRET',
  'ttittulares-image-bridge-v1',
  'imagesAfterMarker'
)){
  if(-not $bridgeText.Contains($needle)){throw "Falta garantía bridge TTiTTulares v18: $needle"}
}

$cmd='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Listener+'"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

function Get-TTiTTularesListeners {
  return @(Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
    ($_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or $_.CommandLine -like "*TTiTTularesMobileChatTriggerListener.ps1*")
  })
}

# Detener únicamente listeners TTiTTulares.
Get-TTiTTularesListeners | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop}catch{} }
$deadline=(Get-Date).AddSeconds(7)
do{
  Start-Sleep -Milliseconds 250
  $remaining=Get-TTiTTularesListeners
}while($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)
if($remaining.Count -gt 0){throw "Quedan listeners TTiTTulares anteriores activos: $($remaining.ProcessId -join ', ')"}

$StdOut=Join-Path $BaseDir "ttittulares-dedicated-stdout.log"
$StdErr=Join-Path $BaseDir "ttittulares-dedicated-stderr.log"
Remove-Item $StdOut,$StdErr -Force -ErrorAction SilentlyContinue

$proc=Start-Process powershell.exe -ArgumentList @(
  "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener
) -WindowStyle Hidden -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru

Start-Sleep -Seconds 4
$proc.Refresh()
if($proc.HasExited){
  Write-Host "ERROR: listener TTiTTulares cerrado al arrancar. ExitCode=$($proc.ExitCode)" -ForegroundColor Red
  if((Test-Path $StdErr) -and (Get-Item $StdErr).Length -gt 0){Get-Content $StdErr -Tail 40}
  throw "El listener TTiTTulares v18 no ha quedado activo."
}

$live=Get-TTiTTularesListeners
if($live.Count -gt 1){
  # Conserva el listener más reciente y elimina duplicados antiguos.
  $keep=$live|Sort-Object CreationDate -Descending|Select-Object -First 1
  $extras=@($live|Where-Object{$_.ProcessId -ne $keep.ProcessId})
  foreach($x in $extras){try{Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
  if($extras.Count -gt 0){Start-Sleep -Milliseconds 700}
  $live=Get-TTiTTularesListeners
}
if($live.Count -ne 1){
  throw "Garantía listener único fallida. PIDs TTiTTulares: $($live.ProcessId -join ', ')"
}
$listenerPid=[int]$live[0].ProcessId

Write-Host "TTITTULARES V18 ACTUALIZADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $listenerPid"
Write-Host "Listener: $Listener"
Write-Host "Bridge IA: $Bridge"
Write-Host "Editorial: Ejecuta TTiTTulares (sin ImageGen)" -ForegroundColor Green
Write-Host "Gag IA: selección manual + jobs independientes, máximo 1 chat" -ForegroundColor Green
Write-Host "TTendencias: NO MODIFICADO" -ForegroundColor Green
Write-Host "Inicio con Windows: $StartupCmd"
