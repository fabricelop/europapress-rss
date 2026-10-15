#requires -Version 5.1
# Read-only: verify iPhone's direct decisions in isolated TTActualidad pilot.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'TT_Recuperacion\TTActualidadPilot'
$configFile = Join-Path $root 'wrangler.jsonc'
$keyFile = Join-Path $root 'pilot-token.dpapi.txt'
$base = 'https://ttactualidad-decisions-pilot.fabricelop.workers.dev'
if (!(Test-Path -LiteralPath $configFile) -or !(Test-Path -LiteralPath $keyFile)) {
  throw 'Falta la configuracion o clave cifrada del piloto en este PC.'
}
$cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$bindings = @($cfg.kv_namespaces | Where-Object { $_.binding -ceq 'PILOT_DECISIONS' })
if ($cfg.name -cne 'ttactualidad-decisions-pilot' -or $bindings.Count -ne 1 -or
    [string]$bindings[0].id -cne '231e2ba56ef443f9be857e23a5881847') {
  throw 'La configuracion no es la del piloto aislado; no se consulta nada.'
}
$health = Invoke-RestMethod -Uri ($base + '/health') -TimeoutSec 20
if (!$health.ok -or $health.kind -cne 'isolated-ttactualidad-pilot' -or $health.production_connected -ne $false) {
  throw 'La identidad o aislamiento del Worker no coincide con el piloto.'
}
$encrypted = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
$secret = ConvertTo-SecureString -String $encrypted
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
if (!$token -or $token.Length -lt 32) { throw 'Clave privada local invalida.' }
$header = @{ Authorization = ('Bearer ' + $token) }
Write-Host '=== VERIFICACION DIRECTA DEL IPHONE: SOLO LECTURA ===' -ForegroundColor Cyan
$response = Invoke-RestMethod -Uri ($base + '/api/decisions') -Headers $header -TimeoutSec 30
if (!$response.ok -or $response.mode -cne 'pilot_only') { throw 'El Worker no devuelve una bandeja piloto valida.' }
$items = @($response.items | Where-Object { $null -ne $_ })
$mobile = @($items | Where-Object {
  $_.project -ceq 'ttittulares' -and $_.mode -ceq 'pilot_only' -and
  $_.event_id -match '^pilot-mobile-[0-9a-f]{32}$' -and
  $_.decision -in @('prepare','discard')
})
$prepare = @($mobile | Where-Object { $_.decision -ceq 'prepare' })
$discard = @($mobile | Where-Object { $_.decision -ceq 'discard' })
Write-Host ('Decisiones en primera pagina: ' + $items.Count)
Write-Host ('Decisiones del iPhone - Elaborar: ' + $prepare.Count)
Write-Host ('Decisiones del iPhone - Desestimar: ' + $discard.Count)
Write-Host ('Paginacion pendiente: ' + [string]$response.has_more)
if ($mobile.Count) {
  $mobile | Sort-Object received_at -Descending | Select-Object -First 10 |
    ForEach-Object { Write-Host ('REGISTRADA: ' + $_.decision + ' | ' + $_.received_at + ' UTC') }
}
if ($prepare.Count -gt 0 -and $discard.Count -gt 0) {
  Write-Host 'RESULTADO OK: las dos acciones de prueba del iPhone estan almacenadas en el KV piloto.' -ForegroundColor Green
} else {
  Write-Host 'RESULTADO PENDIENTE: aun no se observan ambas acciones en la primera pagina.' -ForegroundColor Yellow
  if ($response.has_more) { Write-Host 'Hay paginacion: esta comprobacion no ha examinado todas las entradas.' }
  Write-Host 'Si los botones mostraron error, comparte solo el texto del error, nunca la clave.'
}
Write-Host 'No se han modificado Cloudflare, GitHub, PC, Telegram ni produccion.'
