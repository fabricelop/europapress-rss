# Install-TTiTTulares-Listener-v48.ps1
# Actualiza SOLO el listener TTiTTulares a v48.
# No toca TTendencias, Chrome 9223, watchdog, updater ni datos remotos.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="2fb7eb42363dd111742120e6e97956e971642462"
$Listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Tmp=Join-Path $BaseDir "TTiTTularesDedicatedListener.v48.new.ps1"
$State=Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$Log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"

$url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TTiTTularesDedicatedListener.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -Uri $url -OutFile $Tmp -UseBasicParsing -Headers @{
  "User-Agent"="TTiTTulares-v48-installer"
  "Cache-Control"="no-cache, no-store"
  "Pragma"="no-cache"
} -TimeoutSec 30

if(-not (Test-Path -LiteralPath $Tmp) -or (Get-Item -LiteralPath $Tmp).Length -lt 5000){
  throw "Descarga del listener v48 invalida"
}
$txt=Get-Content -LiteralPath $Tmp -Raw -Encoding UTF8
if(-not $txt.Contains('$WorkerId = "ttittulares-dedicated-v48"')){throw "El listener descargado no es v48"}
if(-not $txt.Contains('TTiTTulares-Dedicated-Listener-v48')){throw "Falta lectura Vercel-first v48"}

$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($Tmp,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count -gt 0){throw "PowerShell v48 invalido: "+(($errors|ForEach-Object{$_.Message}) -join " | ")}

# Parar SOLO listener TTiTTulares y cualquier bridge TTiTTulares huérfano.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  (($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*") -or
  (($_.Name -ieq "node.exe" -or $_.Name -ieq "node") -and $_.CommandLine -like "*TTiTTularesImageBridge.js*")
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 700

# Limpiar únicamente activos locales huérfanos; conservar historial de vistos.
if(Test-Path -LiteralPath $State){
  try{
    $s=Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    if($s.PSObject.Properties.Name -contains "active_image_commands"){
      $s.active_image_commands=@()
    }else{
      $s | Add-Member -NotePropertyName active_image_commands -NotePropertyValue @() -Force
    }
    $s | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $State -Encoding UTF8
  }catch{
    Write-Host "AVISO: no pude sanear active_image_commands: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
Remove-Item -LiteralPath (Join-Path $BaseDir "ttittulares-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $BaseDir "ttittulares-image-tab.json") -Force -ErrorAction SilentlyContinue

Move-Item -LiteralPath $Tmp -Destination $Listener -Force

$ps=Get-Command powershell.exe -ErrorAction SilentlyContinue
if(-not $ps){throw "No encuentro powershell.exe"}
$p=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Listener) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 5

if($p.HasExited){throw "El listener v48 termino al arrancar. ExitCode=$($p.ExitCode)"}

Write-Host "TTITTULARES LISTENER v48 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID TTiTTulares: $($p.Id)"
Write-Host "Lectura image-job: Vercel strong primero; RAW GitHub solo fallback"
Write-Host "TTendencias/Chrome 9223/watchdog/updater: sin cambios"
Write-Host ""
Write-Host "Ultimas lineas:"
if(Test-Path -LiteralPath $Log){Get-Content -LiteralPath $Log -Tail 14}
