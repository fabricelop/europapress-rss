# TTActualidad V2 - Prueba REAL y supervisada de aislamiento Chrome.
# No utiliza Chrome 9223, no usa el perfil habitual y no envia ordenes editoriales.
param([int]$TimeoutSeconds = 180)
$ErrorActionPreference='Stop'
if($TimeoutSeconds -lt 30 -or $TimeoutSeconds -gt 900){throw 'TimeoutSeconds debe estar entre 30 y 900'}
$chrome=@(
  "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if(-not $chrome){throw 'Chrome no encontrado; no se ha iniciado nada'}
$base=Join-Path $env:TEMP ('ttactualidad-v2-browser-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $base 'profile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$p=$null
$stopwatch=[Diagnostics.Stopwatch]::StartNew()
try {
  Write-Host 'TT_V2_BROWSER_TEST_START: instancia aislada; NO se usa el Chrome principal.'
  Write-Host 'Se abrira ChatGPT en un perfil temporal NUEVO. Puede pedir inicio de sesion.'
  $args=@("--user-data-dir=$profile","--no-first-run","--no-default-browser-check","--new-window","https://chatgpt.com/")
  $p=Start-Process -FilePath $chrome -ArgumentList $args -PassThru
  Write-Host "TT_V2_BROWSER_PID=$($p.Id)"
  Write-Host 'Comprueba que la ventana se abre. NO envies trabajos reales.'
  Write-Host 'Pulsa ENTER en esta consola cuando hayas terminado de comprobar la ventana.'
  $inputTask=[System.Threading.Tasks.Task]::Run([Action]{ [Console]::ReadLine() | Out-Null })
  while(-not $inputTask.IsCompleted -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
    Start-Sleep -Milliseconds 500
    $p.Refresh()
    if($p.HasExited){break}
  }
  if($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds){Write-Host 'TT_V2_BROWSER_TIMEOUT'}
} finally {
  # Cerrar solo los procesos cuyo CommandLine contiene este perfil exclusivo.
  # Nunca terminar procesos del perfil habitual ni los de CDP 9223.
  $targets=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
  foreach($target in $targets){
    try { Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop } catch {
      Write-Warning "No se pudo cerrar PID $($target.ProcessId): $_"
    }
  }
  Start-Sleep -Milliseconds 500
  $remaining=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
  if($remaining.Count -eq 0){
    Write-Host 'TT_V2_BROWSER_CLOSED_VERIFIED'
    try {Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction Stop; Write-Host 'TT_V2_TEMP_PROFILE_REMOVED'}catch{Write-Warning 'Perfil temporal pendiente de limpieza'}
  }else{
    Write-Host "TT_V2_BROWSER_CLOSE_FAILED remaining=$($remaining.Count)"
    Write-Warning "Perfil temporal conservado para diagnostico: $base"
  }
}
