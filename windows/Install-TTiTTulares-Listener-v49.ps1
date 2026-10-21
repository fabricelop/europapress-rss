# Install-TTiTTulares-Listener-v49.ps1
# Actualiza SOLO el listener TTiTTulares a v49.
# No toca bridges activos, TTendencias, Chrome 9223, watchdog ni updater.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="4dd93c8edf29db020696937d614cc1843e57ea38"
$Listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Tmp=Join-Path $BaseDir "TTiTTularesDedicatedListener.v49.new.ps1"
$Log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"

$url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TTiTTularesDedicatedListener.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-WebRequest -Uri $url -OutFile $Tmp -UseBasicParsing -Headers @{
  "User-Agent"="TTiTTulares-v49-installer"
  "Cache-Control"="no-cache, no-store"
  "Pragma"="no-cache"
} -TimeoutSec 30

if(-not (Test-Path -LiteralPath $Tmp) -or (Get-Item -LiteralPath $Tmp).Length -lt 5000){
  throw "Descarga del listener v49 invalida"
}
$txt=Get-Content -LiteralPath $Tmp -Raw -Encoding UTF8
if(-not $txt.Contains('$WorkerId = "ttittulares-dedicated-v49"')){throw "El listener descargado no es v49"}
if(-not $txt.Contains('IMAGE BRIDGE LOCAL VALID v49 no-refresh')){throw "Falta bridge local-first v49"}
if(-not $txt.Contains('TTiTTulares-Dedicated-Listener-v48')){throw "Falta lectura image-job Vercel-first"}

$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($Tmp,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count -gt 0){throw "PowerShell v49 invalido: "+(($errors|ForEach-Object{$_.Message}) -join " | ")}

# Parar SOLO el listener TTiTTulares actual.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*"
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 700

Move-Item -LiteralPath $Tmp -Destination $Listener -Force

$ps=Get-Command powershell.exe -ErrorAction SilentlyContinue
if(-not $ps){throw "No encuentro powershell.exe"}
$p=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Listener) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 5
if($p.HasExited){throw "El listener v49 termino al arrancar. ExitCode=$($p.ExitCode)"}

Write-Host "TTITTULARES LISTENER v49 INSTALADO Y ACTIVO" -ForegroundColor Green
Write-Host "PID TTiTTulares: $($p.Id)"
Write-Host "Bridge local valido: uso inmediato, sin descarga GitHub por imagen"
Write-Host "Image-job: Vercel strong primero; RAW GitHub solo fallback"
Write-Host "TTendencias/Chrome 9223/bridges/watchdog/updater: sin cambios"
Write-Host ""
Write-Host "Ultimas lineas:"
if(Test-Path -LiteralPath $Log){Get-Content -LiteralPath $Log -Tail 14}
