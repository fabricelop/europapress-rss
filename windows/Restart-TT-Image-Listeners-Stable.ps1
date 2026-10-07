# Restart-TT-Image-Listeners-Stable.ps1
# Reinicio quirurgico de listeners TT tras restaurar bridges estables.
# No toca editorial, watchdog, updater, Ejecutar.js ni datos remotos.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$TTListener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$TRListener=Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$TTBridge=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$TRBridge=Join-Path $BaseDir "TTendenciasImageBridge.js"
$TTState=Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$TRState=Join-Path $BaseDir "ttendencias-mobile-trigger-state.json"
$TTLog=Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$TRLog=Join-Path $BaseDir "ttendencias-mobile-trigger.log"

function Validate-File([string]$Path,[string]$Needle,[string]$Label){
  if(-not (Test-Path -LiteralPath $Path)){throw "No existe $Label: $Path"}
  $txt=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if(-not $txt.Contains($Needle)){throw "$Label no tiene la version esperada"}
}
Validate-File $TTListener 'ttittulares-dedicated-v47' 'listener TTiTTulares'
Validate-File $TRListener 'ttendencias-dedicated-v16' 'listener TTendencias'
Validate-File $TTBridge 'BRIDGE_MODE="capture-only-v28-dead-submit-retry"' 'bridge TTiTTulares'
Validate-File $TRBridge 'BRIDGE_MODE="capture-only-v28-dead-submit-retry"' 'bridge TTendencias'

$node=Get-Command node.exe -ErrorAction SilentlyContinue
if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
if(-not $node){throw "No encuentro Node.js"}
& $node.Source --check $TTBridge 1>$null 2>$null
if($LASTEXITCODE -ne 0){throw "TTiTTulares bridge no pasa node --check"}
& $node.Source --check $TRBridge 1>$null 2>$null
if($LASTEXITCODE -ne 0){throw "TTendencias bridge no pasa node --check"}

# Parar SOLO listeners dedicados y bridges de imagen.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*" -or
   $_.CommandLine -like "*TTendenciasDedicatedListener.ps1*" -or
   $_.CommandLine -like "*TTiTTularesImageBridge.js*" -or
   $_.CommandLine -like "*TTendenciasImageBridge.js*")
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 700

# Limpiar solo la lista de jobs activos locales; conservar historial de vistos.
foreach($statePath in @($TTState,$TRState)){
  if(Test-Path -LiteralPath $statePath){
    try{
      $s=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if($s.PSObject.Properties.Name -contains "active_image_commands"){
        $s.active_image_commands=@()
      }else{
        $s | Add-Member -NotePropertyName active_image_commands -NotePropertyValue @() -Force
      }
      $s | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }catch{
      Write-Host "AVISO: no pude sanear $statePath :: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
}

Remove-Item -LiteralPath (Join-Path $BaseDir "ttittulares-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $BaseDir "ttendencias-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue

$ps=Get-Command powershell.exe -ErrorAction SilentlyContinue
if(-not $ps){throw "No encuentro powershell.exe"}

$tt=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$TTListener) -WindowStyle Hidden -PassThru
$tr=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$TRListener) -WindowStyle Hidden -PassThru

Start-Sleep -Seconds 5

Write-Host "LISTENERS TT REINICIADOS SOBRE BRIDGES ESTABLES" -ForegroundColor Green
Write-Host "PID TTiTTulares: $($tt.Id)"
Write-Host "PID TTendencias: $($tr.Id)"
Write-Host ""
Write-Host "Ultimas lineas TTiTTulares:"
if(Test-Path $TTLog){Get-Content -LiteralPath $TTLog -Tail 8}
Write-Host ""
Write-Host "Ultimas lineas TTendencias:"
if(Test-Path $TRLog){Get-Content -LiteralPath $TRLog -Tail 12}
