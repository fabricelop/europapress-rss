#requires -Version 5.1
# Verify existing TTActualidad pilot without creating Workers, KV or secrets.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$name='ttactualidad-decisions-pilot'
$kvId='231e2ba56ef443f9be857e23a5881847'
$url='https://ttactualidad-decisions-pilot.fabricelop.workers.dev'
$root=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$config=Join-Path $root 'wrangler.jsonc'
$wrangler=Join-Path $root 'node_modules\.bin\wrangler.cmd'
$tokenFile=Join-Path $root 'pilot-token.dpapi.txt'
$workerFile=Join-Path $root 'ttactualidad-worker.js'
function Step([string]$name){Write-Host '';Write-Host ('=== '+$name+' ===') -ForegroundColor Cyan}
Step 'CONFIRMAR RECURSOS EXISTENTES'
foreach($f in @($config,$wrangler,$tokenFile,$workerFile)){
 if(!(Test-Path -LiteralPath $f)){throw ('Falta archivo necesario: '+$f)}
}
$c=Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json
$kv=@($c.kv_namespaces|Where-Object{$_.binding -ceq 'PILOT_DECISIONS'})
if($c.name -cne $name -or $c.main -cne './ttactualidad-worker.js' -or
   @($c.kv_namespaces).Count -ne 1 -or $kv.Count -ne 1 -or [string]$kv[0].id -cne $kvId){
 throw 'El Worker o KV local no coincide con el piloto; no se modifica nada.'
}
$h=Invoke-RestMethod -Uri ($url+'/health') -TimeoutSec 30
if(!$h.ok -or $h.kind -cne 'isolated-ttactualidad-pilot' -or $h.production_connected -ne $false){
 throw 'El endpoint publico no confirma que sea el piloto aislado.'
}
Step 'ACTUALIZAR SOLO WORKER PILOTO, SIN CREAR KV NI SECRETOS'
$remote='https://raw.githubusercontent.com/fabricelop/europapress-rss/pilot/ttactualidad-direct-decisions-20261015/pilot/ttactualidad-worker.js'
$temp=Join-Path $root 'pilot-worker-check.mjs'
Invoke-WebRequest -UseBasicParsing -Uri $remote -OutFile $temp -TimeoutSec 45
$newText=[IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
if(!$newText.Contains("route==='/api/decision'&&request.method==='GET'") -or
   !$newText.Contains('production_connected:false')){throw 'Version inesperada del Worker piloto.'}
try{
 & node.exe --check $temp
 if($LASTEXITCODE -ne 0){throw 'Sintaxis JavaScript invalida'}
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
$backup=$workerFile+'.before-lookup-verify.bak'
if(!(Test-Path -LiteralPath $backup)){Copy-Item -LiteralPath $workerFile -Destination $backup}
[IO.File]::WriteAllText($workerFile,$newText,([Text.UTF8Encoding]::new($false)))
Push-Location $root
try{
 $oldPreference=$ErrorActionPreference
 try{
  $ErrorActionPreference='Continue'
  & $wrangler deploy --config $config
  $exit=$LASTEXITCODE
 }finally{$ErrorActionPreference=$oldPreference}
 if($exit -ne 0){throw ('Wrangler devolvio '+$exit)}
}finally{Pop-Location}
Step 'RECUPERAR CLAVE LOCAL CIFRADA'
$cipher=(Get-Content -LiteralPath $tokenFile -Raw -Encoding UTF8).Trim()
$secure=ConvertTo-SecureString -String $cipher
$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}
finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
if($token.Length -lt 32){throw 'Clave local inesperada'}
$headers=@{Authorization=('Bearer '+$token)}
$authenticated=Invoke-RestMethod -Uri ($url+'/api/decisions') -Headers $headers -TimeoutSec 30
if(!$authenticated.ok -or $authenticated.mode -cne 'pilot_only'){
 throw 'Autenticacion del piloto no confirmada'
}
Step 'PRUEBA DE DECISION AISLADA'
$event='pilot-check-'+[guid]::NewGuid().ToString('N')
$body=@{
 project='ttittulares'
 event_id=$event
 decision='prepare'
 request_id=[guid]::NewGuid().ToString()
}|ConvertTo-Json -Compress
$reply=Invoke-RestMethod -Uri ($url+'/api/decision') -Headers $headers -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 30
if(!$reply.ok -or !$reply.stored -or $reply.production_connected -ne $false){
 throw 'El piloto no confirmo la escritura.'
}
Step 'ESPERAR PROPAGACION DEL KV (HASTA 100 SEGUNDOS)'
$found=$false
for($i=1;$i -le 20;$i++){
 $target=$url+'/api/decision?project=ttittulares&event_id='+[uri]::EscapeDataString($event)
 $check=Invoke-RestMethod -Uri $target -Headers $headers -TimeoutSec 25
 if($check.ok -and $check.found -and
    $check.item.event_id -ceq $event -and $check.item.decision -ceq 'prepare' -and
    $check.production_connected -eq $false){$found=$true;break}
 if($i -lt 20){Start-Sleep -Seconds 5}
}
if(!$found){throw 'La escritura fue aceptada, pero todavia no se ve tras la espera; no se ha tocado produccion.'}
try{
 Set-Clipboard -Value $token -ErrorAction Stop
 Write-Host 'Clave privada copiada al portapapeles (no mostrada).'
}catch{Write-Warning 'Clave conservada cifrada; no se pudo copiar al portapapeles.'}
Write-Host 'PILOTO OK: autorizacion, escritura y lectura individual verificadas.' -ForegroundColor Green
Write-Host ('URL: '+$url+'/')
Write-Host 'NO se han enviado acciones a TTiTTulares, TTendencias o Telegram.'
