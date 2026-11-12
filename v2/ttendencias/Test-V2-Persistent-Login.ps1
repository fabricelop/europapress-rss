# TTActualidad V2: perfil exclusivo persistente; prueba manual de login.
# No usa CDP ni el Chrome de V1. No borra el perfil de autenticacion.
param([ValidateSet('login','verify','verify-clean')][string]$Mode='login',[int]$TimeoutSeconds=240)
$ErrorActionPreference='Stop'
if($TimeoutSeconds -lt 30 -or $TimeoutSeconds -gt 900){throw 'TimeoutSeconds debe estar entre 30 y 900'}
$chrome=@(
  "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
) | Where-Object {$_ -and (Test-Path -LiteralPath $_)} | Select-Object -First 1
if(-not $chrome){throw 'Chrome no encontrado'}
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$profile=Join-Path $root 'ChromeProfile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
function Get-V2Processes {
  @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object {$_.CommandLine -and $_.CommandLine.Contains($profile)})
}
if((Get-V2Processes).Count -gt 0){throw 'Ya hay una instancia de Chrome V2 usando este perfil. Cierra esa ventana antes de continuar.'}
$seen=$false
$window=$false
$launched=$null
try {
  Write-Host "TT_V2_AUTH_MODE=$Mode"
  Write-Host "TT_V2_AUTH_PROFILE=$profile"
  Write-Host 'Abre ChatGPT. En login inicia sesion manualmente; en verify comprueba tus conversaciones.'
  Write-Host 'El perfil se conserva entre ejecuciones. NO introduzcas credenciales en PowerShell.'
  $args=@("--user-data-dir=`"$profile`"","--no-first-run","--no-default-browser-check","--new-window","https://chatgpt.com/")
  if($Mode -eq "verify-clean"){$args=@("--disable-extensions") + $args;Write-Host "TT_V2_EXTENSIONS_DISABLED=YES"}
  $launched=Start-Process -FilePath $chrome -ArgumentList $args -PassThru
  Write-Host "TT_V2_AUTH_LAUNCH_PID=$($launched.Id)"
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Seconds 1
    $processes=Get-V2Processes
    if($processes.Count -gt 0){$seen=$true}
    foreach($proc in $processes){
      try{
        $gp=Get-Process -Id $proc.ProcessId -ErrorAction Stop
        if($gp.MainWindowHandle -ne 0){$window=$true}
      }catch{}
    }
    # Mantener abierta hasta que el usuario cierre la ventana o se agote el plazo.
    if($watch.Elapsed.TotalSeconds -ge 5 -and $processes.Count -eq 0){break}
  }
  Write-Host "TT_V2_AUTH_PROCESS_SEEN=$seen"
  Write-Host "TT_V2_AUTH_WINDOW_SEEN=$window"
  Write-Host 'TT_V2_AUTH_LOGIN_VERIFIED=MANUAL_ONLY'
} finally {
  # No tocar Chrome principal: solo procesos que incluyen ruta exclusiva de V2.
  $targets=Get-V2Processes
  foreach($proc in $targets) {
    try {Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop}
    catch {Write-Warning "No se pudo cerrar PID $($proc.ProcessId): $_"}
  }
  Start-Sleep -Seconds 2
  $remaining=Get-V2Processes
  Write-Host "TT_V2_AUTH_REMAINING=$($remaining.Count)"
  if($remaining.Count -eq 0){Write-Host 'TT_V2_AUTH_BROWSER_CLOSED=YES'}
  else{Write-Warning 'Cierre incompleto: NO iniciar otra instancia V2'}
  Write-Host 'TT_V2_AUTH_PROFILE_PRESERVED=YES'
}
