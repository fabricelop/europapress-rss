# TTActualidad V2 - Diagnostico supervisado Chrome aislado (sin tocar V1).
param([int]$TimeoutSeconds = 180)
$ErrorActionPreference='Stop'
if($TimeoutSeconds -lt 30 -or $TimeoutSeconds -gt 900){throw 'TimeoutSeconds fuera de rango'}
$chrome=@(
  "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if(-not $chrome){throw 'Chrome no encontrado'}
$base=Join-Path $env:TEMP ('ttactualidad-v2-browser-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $base 'profile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$seenProcess=$false
$seenWindow=$false
$exitCode=$null
$started=$false
$closeVerified=$false
try {
  Write-Host "TT_V2_CHROME_PATH=$chrome"
  Write-Host "TT_V2_PROFILE=$profile"
  $arguments=@("--user-data-dir=`"$profile`"","--no-first-run","--no-default-browser-check","--new-window","https://chatgpt.com/")
  $p=Start-Process -FilePath $chrome -ArgumentList $arguments -PassThru
  $started=$true
  Write-Host "TT_V2_LAUNCH_PID=$($p.Id)"
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Seconds 1
    $matches=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
    if($matches.Count -gt 0){$seenProcess=$true}
    foreach($proc in $matches){
      try {
        $gp=Get-Process -Id $proc.ProcessId -ErrorAction Stop
        if($gp.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($gp.MainWindowTitle)){$seenWindow=$true}
      }catch{}
    }
    $p.Refresh()
    if($p.HasExited -and $null -eq $exitCode){$exitCode=$p.ExitCode}
    if($clock.Elapsed.TotalSeconds -ge 5 -and $matches.Count -eq 0){break}
    if($seenWindow -and $matches.Count -eq 0){break}
  }
  Write-Host "TT_V2_PROCESS_SEEN=$seenProcess"
  Write-Host "TT_V2_WINDOW_DETECTED=$seenWindow"
  if($null -ne $exitCode){Write-Host "TT_V2_LAUNCH_EXIT_CODE=$exitCode"}
  if(-not $seenWindow){Write-Warning 'No se ha verificado ninguna ventana visible: prueba NO superada'}
  else{Write-Host 'TT_V2_WINDOW_OBSERVED: prueba de apertura superada'}
} finally {
  # Nunca cerrar Chrome principal: solo procesos con nuestro perfil unico.
  $targets=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
  foreach($target in $targets){
    try {Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop}
    catch{Write-Warning "Error al cerrar PID $($target.ProcessId): $_"}
  }
  Start-Sleep -Milliseconds 700
  $remaining=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
  $closeVerified=($remaining.Count -eq 0)
  if($closeVerified){Write-Host 'TT_V2_BROWSER_CLOSED_VERIFIED'}
  else{Write-Warning "Quedan $($remaining.Count) procesos asociados al perfil temporal"}
  if($seenWindow -and $closeVerified){
    try{Remove-Item -LiteralPath $base -Recurse -Force;Write-Host 'TT_V2_TEMP_PROFILE_REMOVED'}
    catch{Write-Warning "No se pudo borrar el perfil temporal: $base"}
  }else{
    Write-Host "TT_V2_DIAGNOSTIC_PROFILE_RETAINED=$base"
  }
  if(-not $seenWindow -or -not $closeVerified){Write-Host 'TT_V2_RESULT=FAIL'}
  else{Write-Host 'TT_V2_RESULT=PASS'}
}
