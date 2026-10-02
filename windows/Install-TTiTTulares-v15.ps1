# Install-TTiTTulares-v15.ps1
# Instalador inmutable SOLO para TTiTTulares v15.
# No modifica TTendencias ni Ejecutar.js.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Listener = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupCmd = Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"
$ListenerUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/97ada1f9e657e766a83fb375a42bbfe46bb3c588/windows/TTiTTularesDedicatedListener.ps1"

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Invoke-WebRequest -Uri $ListenerUrl -OutFile $Listener -UseBasicParsing

$tokens=$null;$parseErrors=$null
[System.Management.Automation.Language.Parser]::ParseFile($Listener,[ref]$tokens,[ref]$parseErrors)|Out-Null
if($parseErrors.Count -gt 0){throw "Listener v15 con errores de sintaxis."}

$listenerText=Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
foreach($needle in @(
  '$WorkerId = "ttittulares-dedicated-v15"',
  'ArgumentList @($Runner,"titulares","--enviar")',
  'Remove-Item Env:TT_CHAT_MESSAGE_B64',
  'Mensaje preparado:\s*Ejecuta TTiTTulares',
  'EDITORIAL PROCESS STARTED direct-node-real-default-message'
)){
  if(-not $listenerText.Contains($needle)){throw "Falta garantía v15: $needle"}
}

$Runner=Join-Path $BaseDir "Ejecutar.js"
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

$cmd='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Listener+'"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII

function Get-TTiTTularesListeners {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or
    $_.CommandLine -like "*TTiTTularesMobileChatTriggerListener.ps1*"
  })
}

Get-TTiTTularesListeners | ForEach-Object { try{Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop}catch{} }

$deadline=(Get-Date).AddSeconds(6)
do{
  Start-Sleep -Milliseconds 250
  $remaining=Get-TTiTTularesListeners
}while($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)
if($remaining.Count -gt 0){throw "Quedan listeners TTiTTulares anteriores activos."}

$log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$offset=0L
if(Test-Path -LiteralPath $log){try{$offset=(Get-Item -LiteralPath $log).Length}catch{}}

Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener) -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 4

$active=@(Get-TTiTTularesListeners)
if($active.Count -ne 1){throw "Se esperaba exactamente un listener TTiTTulares v15."}
$pid=[int]$active[0].ProcessId

$newLog=""
if(Test-Path -LiteralPath $log){
  $fs=[System.IO.File]::Open($log,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
  try{
    if($offset -gt $fs.Length){$offset=0}
    [void]$fs.Seek($offset,[System.IO.SeekOrigin]::Begin)
    $sr=New-Object System.IO.StreamReader($fs,[System.Text.Encoding]::UTF8,$true,4096,$true)
    try{$newLog=$sr.ReadToEnd()}finally{$sr.Dispose()}
  }finally{$fs.Dispose()}
}
if($newLog -notmatch ("LISTENER START worker=ttittulares-dedicated-v15 pid="+[regex]::Escape([string]$pid))){
  try{Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue}catch{}
  throw "No se confirmó worker v15 en el log nuevo."
}

Write-Host "TTITTULARES V15 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID: $pid"
Write-Host "Invocación editorial: node Ejecutar.js titulares --enviar"
Write-Host "Mensaje editorial: Ejecuta TTiTTulares"
Write-Host "TTendencias: NO MODIFICADO" -ForegroundColor Green
Write-Host "Ejecutar.js: validado, NO MODIFICADO" -ForegroundColor Green
