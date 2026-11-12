# V2 5B: comprobar ChatGPT autenticado en Chrome efimero mediante CDP aislado.
# SOLO lectura: no envia prompts, no escribe GitHub, no toca Chrome 9223.
param([int]$TimeoutSeconds=90)
$ErrorActionPreference='Stop'
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'
if(-not (Test-Path $chrome)){throw 'Chrome no encontrado'}
$base=Join-Path $env:TEMP ('tt-v2-auth-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $base 'profile'
New-Item -ItemType Directory -Force -Path $profile | Out-Null
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$opened=$false
try{
  $args=@("--user-data-dir=`"$profile`"","--remote-debugging-address=127.0.0.1","--remote-debugging-port=$port","--no-first-run","--no-default-browser-check","--new-window","https://chatgpt.com/")
  $p=Start-Process -FilePath $chrome -ArgumentList $args -PassThru
  Write-Host "TT_V2_AUTH_CHROME_PID=$($p.Id)"
  Write-Host "TT_V2_AUTH_CDP_PORT=$port"
  Write-Host 'Comprueba visualmente si aparecen tus conversaciones habituales. No envies ningun mensaje.'
  $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
  while((Get-Date) -lt $deadline){
    Start-Sleep -Seconds 2
    try{
      $pages=Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 2
      $chat=@($pages | Where-Object {$_.type -eq 'page' -and $_.url -like 'https://chatgpt.com/*'})
      if($chat.Count -gt 0){
        $opened=$true
        Write-Host "TT_V2_AUTH_CDP_CHATGPT_PAGE=YES"
        Write-Host "TT_V2_AUTH_PAGE_TITLE=$($chat[0].title)"
        break
      }
    }catch{}
  }
  if(-not $opened){Write-Host 'TT_V2_AUTH_CDP_CHATGPT_PAGE=NO'}
  Write-Host 'TT_V2_AUTH_MANUAL_CHECK=REQUIRED'
  Write-Host 'La deteccion CDP no verifica autenticacion. Comprueba la sesion visualmente.'
  Start-Sleep -Seconds 15
}finally{
  $targets=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($profile)})
  foreach($target in $targets){try{Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop}catch{Write-Warning "No se pudo cerrar PID $($target.ProcessId)"}}
  Start-Sleep -Milliseconds 500
  $remaining=@(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($profile)})
  if($remaining.Count -eq 0){
    Write-Host 'TT_V2_AUTH_BROWSER_CLOSED=YES'
    try{Remove-Item -LiteralPath $base -Recurse -Force;Write-Host 'TT_V2_AUTH_PROFILE_REMOVED=YES'}catch{Write-Warning "Perfil temporal no eliminado: $base"}
  }else{Write-Host 'TT_V2_AUTH_BROWSER_CLOSED=NO';Write-Host "TT_V2_AUTH_PROFILE=$base"}
}
