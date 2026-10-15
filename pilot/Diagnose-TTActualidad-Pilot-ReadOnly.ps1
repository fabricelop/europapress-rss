#requires -Version 5.1
# TTActualidad pilot diagnostics ONLY. No deploys, secrets, writes or production.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$tokenFile=Join-Path $root 'pilot-token.dpapi.txt'
$config=Join-Path $root 'wrangler.jsonc'
$base='https://ttactualidad-decisions-pilot.fabricelop.workers.dev'
Write-Host '=== DIAGNOSTICO SOLO LECTURA TTActualidad piloto ===' -ForegroundColor Cyan
if(!(Test-Path -LiteralPath $tokenFile) -or !(Test-Path -LiteralPath $config)){throw 'Faltan archivos locales del piloto'}
$cfg=Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
$kv=@($cfg.kv_namespaces | Where-Object {$_.binding -ceq 'PILOT_DECISIONS'})
if($cfg.name -cne 'ttactualidad-decisions-pilot' -or $kv.Count -ne 1 -or
   [string]$kv[0].id -cne '231e2ba56ef443f9be857e23a5881847'){
 throw 'La configuracion local no es la del piloto esperado'
}
$health=Invoke-RestMethod -Uri ($base+'/health') -TimeoutSec 20
if(!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false){
 throw 'El sitio no confirma aislamiento piloto'
}
Write-Host 'Salud y aislamiento: OK'
$encrypted=(Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
$secure=ConvertTo-SecureString -String $encrypted
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
if(!$token -or $token.Length -lt 32){throw 'Clave local invalida'}
$auth=@{Authorization=('Bearer '+$token)}
$list=Invoke-RestMethod -Uri ($base+'/api/decisions') -Headers $auth -TimeoutSec 30
if(!$list.ok -or $list.mode -cne 'pilot_only'){throw 'Error al consultar la bandeja privada del piloto'}
$all=@($list.items)
$tests=@($all | Where-Object {$_.event_id -like 'pilot-install-*' -or $_.event_id -like 'pilot-check-*'})
Write-Host ('Autenticacion: OK. Entradas en la primera pagina: '+$all.Count+'; pruebas anteriores: '+$tests.Count)
Write-Host ('Paginacion pendiente: '+[string]$list.has_more)
Write-Host 'Comprobando si la ruta GET /api/decision esta activa...'
$probe=$base+'/api/decision?project=ttittulares&event_id=pilot-diagnostic-route-001'
$ready=$false
for($i=1;$i -le 8;$i++){
 try {
   $item=Invoke-RestMethod -Uri $probe -Headers $auth -TimeoutSec 20
   if($item.ok -and $item.production_connected -eq $false -and $null -ne $item.found){
     $ready=$true
     Write-Host ('Ruta individual: OK. Existe registro de diagnostico: '+[string]$item.found) -ForegroundColor Green
     break
   }
   Write-Host ('Intento '+$i+': respuesta inesperada de ruta individual.')
 }catch{
   $http=0
   try{$http=[int]$_.Exception.Response.StatusCode}catch{}
   if($http -eq 404){
     Write-Host ('Intento '+$i+': HTTP 404, Worker responde not_found (ruta individual no disponible).')
   }elseif($http -eq 401){
     throw 'La clave ya no se acepta en GET /api/decision, aunque funciono en /api/decisions.'
   }else{
     Write-Host ('Intento '+$i+': solicitud fallida, HTTP '+$http+'; sin imprimir datos privados.')
   }
 }
 if($i -lt 8){Start-Sleep -Seconds 5}
}
if(!$ready){
 Write-Host 'DIAGNOSTICO: la ruta individual sigue ausente. No se ha escrito nada ni se ha desplegado.' -ForegroundColor Yellow
 Write-Host 'Comparte solamente estas lineas de estado; nunca compartas la clave.'
 exit 2
}
try{
 Set-Clipboard -Value $token -ErrorAction Stop
 Write-Host 'Clave piloto copiada al portapapeles de Windows para configurar el iPhone.'
}catch{Write-Warning 'No se pudo copiar la clave; permanece cifrada en el PC.'}
Write-Host 'DIAGNOSTICO OK: Worker listo para recibir y consultar decisiones piloto.' -ForegroundColor Green
Write-Host ('URL del piloto: '+$base+'/')
Write-Host 'No se ha modificado nada en Cloudflare, GitHub main, Telegram o produccion.'
