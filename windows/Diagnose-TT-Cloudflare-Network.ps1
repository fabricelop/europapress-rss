# Diagnostico sin cambios del acceso a Cloudflare de TTendencias/TTiTTulares.
# Ejecutar desde repositorio: powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\Diagnose-TT-Cloudflare-Network.ps1
# No lee ni imprime tokens o secretos. No modifica Cloudflare, GitHub o Windows.
[CmdletBinding()]
param()
$ErrorActionPreference="Continue"

$hosts=@(
  [pscustomobject]@{Name="TTendencias";HostName="ttendencias-no-vercel-test.fabricelop.workers.dev";Path="/health"},
  [pscustomobject]@{Name="TTiTTulares";HostName="ttittulares-no-vercel-test.fabricelop.workers.dev";Path="/health"},
  [pscustomobject]@{Name="Telegram (control)";HostName="tt-control.fabricelop.workers.dev";Path="/api/ttittulares-webhook-version"}
)
function Show-Dns([string]$hostname,[string]$server) {
  $label=if($server){"DNS 1.1.1.1"}else{"DNS sistema"}
  try {
    $args=@{Name=$hostname;Type="A";ErrorAction="Stop"}
    if($server){$args.Server=$server}
    $results=@(Resolve-DnsName @args)
    $ips=@($results | Where-Object {$_.Type -eq "A" -and $_.IPAddress} | ForEach-Object {$_.IPAddress} | Select-Object -Unique)
    if($ips.Count){Write-Host ("{0,-13}: {1}" -f $label,($ips -join ", "));return $true}
    Write-Host ("{0,-13}: sin registros A (resultado DNS sin IP)" -f $label)
    return $false
  }catch {
    Write-Host ("{0,-13}: ERROR {1}" -f $label,$_.Exception.Message)
    return $false
  }
}
function Show-Https([string]$url) {
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if(-not $curl){
    Write-Host "curl.exe no encontrado; Invoke-WebRequest se ejecutara en su lugar."
    try {
      $response=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
      Write-Host ("HTTPS: HTTP "+$response.StatusCode)
    }catch{ Write-Host ("HTTPS: "+$_.Exception.Message) }
    return
  }
  $format="HTTP=%{http_code}  IP=%{remote_ip}  DNS=%{time_namelookup}s  CONNECT=%{time_connect}s  TLS=%{time_appconnect}s  TOTAL=%{time_total}s"
  $lines=@(& $curl.Source --silent --show-error --location --connect-timeout 5 --max-time 10 --output NUL --write-out $format $url 2>&1)
  $exitCode=$LASTEXITCODE
  foreach($line in $lines){Write-Host ("HTTPS: "+[string]$line)}
  Write-Host "curl exit: $exitCode"
}
Write-Host "=== Cloudflare Workers: DNS y HTTPS (SOLO DIAGNOSTICO) ===" -ForegroundColor Cyan
foreach($target in $hosts){
  Write-Host ""
  Write-Host ("--- "+$target.Name+" ---") -ForegroundColor Cyan
  $url="https://"+$target.HostName+$target.Path
  Write-Host "URL: $url"
  $null=Show-Dns $target.HostName ""
  $null=Show-Dns $target.HostName "1.1.1.1"
  Show-Https $url
}
Write-Host ""
Write-Host "Interpretacion:" -ForegroundColor Cyan
Write-Host "* Si control resuelve y las apps no: investigar subdominio/rutas workers.dev."
Write-Host "* Si DNS resuelve pero curl da timeout: investigar conectividad, filtrado o SSL."
Write-Host "* Si curl devuelve HTTP 404/5xx: investigar rutas y logs de esos Workers."
Write-Host "* Si curl devuelve HTTP 200 y navegador no: investigar DNS/proxy/cache del navegador."
Write-Host "No se han alterado Workers, rutas, credenciales ni datos."
