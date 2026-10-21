#requires -Version 5.1
$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
$targets=@(
  @{Name='TTActualidad';Host='ttactualidad-decisions-pilot.fabricelop.workers.dev';Path='/health'},
  @{Name='FabCalendar';Host='fabcalendar-bot.fabricelop.workers.dev';Path='/healthz'}
)
Write-Host '=== DIAGNOSTICO DNS Y CLOUDFLARE (SIN CAMBIOS) ==='
foreach($t in $targets){
  Write-Host ('--- '+$t.Name+' ---')
  try {
    $dns=Resolve-DnsName -Name $t.Host -Type A -ErrorAction Stop
    Write-Host ('DNS_A: '+(($dns | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress) -join ', '))
  }catch{Write-Host ('DNS_A_ERROR: '+$_.Exception.Message)}
  try {
    $dns6=Resolve-DnsName -Name $t.Host -Type AAAA -ErrorAction Stop
    Write-Host ('DNS_AAAA: '+(($dns6 | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress) -join ', '))
  }catch{Write-Host ('DNS_AAAA_ERROR: '+$_.Exception.Message)}
  & curl.exe -4 -sS --connect-timeout 6 --max-time 12 -o NUL -w ('HTTP_IPV4=%{http_code} DNS=%{time_namelookup}s TCP=%{time_connect}s TLS=%{time_appconnect}s TOTAL=%{time_total}s'+[Environment]::NewLine) ('https://'+$t.Host+$t.Path)
  Write-Host ('CURL_IPV4_EXIT='+$LASTEXITCODE)
  & curl.exe -6 -sS --connect-timeout 6 --max-time 12 -o NUL -w ('HTTP_IPV6=%{http_code} DNS=%{time_namelookup}s TCP=%{time_connect}s TLS=%{time_appconnect}s TOTAL=%{time_total}s'+[Environment]::NewLine) ('https://'+$t.Host+$t.Path)
  Write-Host ('CURL_IPV6_EXIT='+$LASTEXITCODE)
}
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
Write-Host '--- TTActualidad local ---'
foreach($f in @('wrangler.jsonc','ttactualidad-worker.js','site\index.html','node_modules\bin\wrangler.cmd','node_modules\.bin\wrangler.cmd')){
  $p=Join-Path $root $f
  Write-Host ($f+': '+(Test-Path -LiteralPath $p))
}
$config=Join-Path $root 'wrangler.jsonc'
if(Test-Path $config){
  try{
    $cfg=Get-Content -Raw -Encoding UTF8 $config | ConvertFrom-Json
    Write-Host ('WORKER_NAME: '+$cfg.name)
    Write-Host ('WORKER_ENTRY: '+$cfg.main)
    Write-Host ('KV_BINDING_PRESENT: '+(@($cfg.kv_namespaces | Where-Object {$_.binding -eq 'PILOT_DECISIONS'}).Count -eq 1))
  }catch{Write-Host ('CONFIG_PARSE_ERROR: '+$_.Exception.Message)}
}
Write-Host 'Diagnostico terminado. No se ha cambiado ni desplegado nada.'
