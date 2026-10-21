# Recuperacion aislada de TTendencias y TTiTTulares en Cloudflare.
# Diagnostico: powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\Repair-TT-Cloudflare-Access.ps1
# Reparacion: powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\Repair-TT-Cloudflare-Access.ps1 -Repair
# No imprime secretos. No toca Telegram, otros Workers, listeners ni colas.
[CmdletBinding()]
param([switch]$Repair)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$targets = @(
  [pscustomobject]@{
    Name = "ttendencias-no-vercel-test"
    Directory = "no-vercel\ttendencias-worker"
    Url = "https://ttendencias-no-vercel-test.fabricelop.workers.dev"
    Page = "/ttendencias/"
    Api = "/api/ttendencias-control?view=state"
  },
  [pscustomobject]@{
    Name = "ttittulares-no-vercel-test"
    Directory = "no-vercel\ttittulares-worker"
    Url = "https://ttittulares-no-vercel-test.fabricelop.workers.dev"
    Page = "/ttittulares/"
    Api = "/api/ttittulares-control"
  }
)

function Request-Status([string]$uri) {
  try {
    $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 7 -MaximumRedirection 3
    return [pscustomobject]@{ OK = ($r.StatusCode -eq 200); Info = "HTTP $($r.StatusCode)"; Http = [int]$r.StatusCode }
  } catch {
    $response = $_.Exception.Response
    $code = 0
    if ($null -ne $response) {
      try { $code = [int]$response.StatusCode } catch {}
    }
    $msg = $_.Exception.Message
    if ($code) { $msg = "HTTP $code : $msg" }
    return [pscustomobject]@{ OK = $false; Info = $msg; Http = $code }
  }
}

function Check-Target($target) {
  Write-Host ""
  Write-Host "==== $($target.Name) ====" -ForegroundColor Cyan
  $checks = @(
    [pscustomobject]@{ Label="Worker"; Path="/health" },
    [pscustomobject]@{ Label="App"; Path=$target.Page },
    [pscustomobject]@{ Label="GAG / imagen"; Path="/tt-shared/gag-copy.html" },
    [pscustomobject]@{ Label="API editorial"; Path=$target.Api }
  )
  $healthy = $true
  $workerReachable = $true
  foreach ($c in $checks) {
    if (-not $workerReachable) {
      Write-Host ("{0,-15} {1}" -f $c.Label,"omitido: /health no responde")
      continue
    }
    Write-Host ("Comprobando {0}: {1}" -f $c.Label,($target.Url + $c.Path)) -ForegroundColor DarkGray
    $v = Request-Status ($target.Url + $c.Path)
    if (-not $v.OK) {
      $healthy = $false
      if ($c.Label -eq "Worker") { $workerReachable = $false }
    }
    Write-Host ("{0,-15} {1}" -f $c.Label,$v.Info)
  }
  return $healthy
}

function Run-Checked([string]$program, [string[]]$arguments) {
  Write-Host ("> " + $program + " " + ($arguments -join " ")) -ForegroundColor DarkCyan
  & $program @arguments
  if ($LASTEXITCODE -ne 0) { throw "Fallo ($LASTEXITCODE): $program $($arguments -join ' ')" }
}

Write-Host "RECUPERACION CLOUDFLARE - diagnostico inicial" -ForegroundColor Cyan
$broken = @()
foreach ($target in $targets) {
  if (-not (Check-Target $target)) { $broken += $target }
}
Write-Host ""
Write-Host "==== Webhook independiente (solo comprobar) ====" -ForegroundColor Cyan
Write-Host "Comprobando tt-control (webhook; solo lectura)..." -ForegroundColor DarkGray
$callback = Request-Status "https://tt-control.fabricelop.workers.dev/api/ttittulares-webhook-version"
Write-Host ("tt-control: " + $callback.Info)

if ($broken.Count -eq 0) {
  Write-Host "Ambas apps, APIs y paginas GAG responden HTTP 200." -ForegroundColor Green
  if (-not $callback.OK) {
    Write-Warning "El webhook independiente tt-control no responde. No se ha modificado."
  }
  exit 0
}

Write-Warning ("Comprobaciones fallidas en: " + (($broken | ForEach-Object { $_.Name }) -join ", "))
if (-not $Repair) {
  Write-Host "Diagnostico sin cambios. Para recuperar las dos apps ejecuta este script con -Repair."
  Write-Host "Si falla tambien tt-control, comprobad subdominio workers.dev y Cloudflare Access antes de otro despliegue."
  exit 2
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js no instalado." }
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw "npm no instalado." }
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { throw "npx no instalado." }

$failure = @()
foreach ($target in $broken) {
  Write-Host ""
  Write-Host ("==== Recuperar solo " + $target.Name + " ====") -ForegroundColor Cyan
  $folder = Join-Path $root $target.Directory
  if (-not (Test-Path (Join-Path $folder "wrangler.jsonc"))) {
    $failure += "$($target.Name): no existe wrangler.jsonc"
    continue
  }
  $cfg = Get-Content (Join-Path $folder "wrangler.jsonc") -Raw
  if ($cfg -notmatch '"workers_dev"\s*:\s*true') {
    $failure += "$($target.Name): workers_dev no esta habilitado en la configuracion"
    continue
  }
  Push-Location $folder
  try {
    Run-Checked "npm" @("install","--no-audit","--no-fund")
    Run-Checked "npx" @("wrangler","whoami")
    Run-Checked "npm" @("test")
    Run-Checked "npx" @("wrangler","deploy","--dry-run")
    # --keep-vars conserva variables creadas en Cloudflare Dashboard.
    # Wrangler tambien conserva los secretos existentes en el mismo Worker.
    Run-Checked "npx" @("wrangler","deploy","--keep-vars")
  } catch {
    $failure += "$($target.Name): $($_.Exception.Message)"
  } finally {
    Pop-Location
  }
}
Write-Host ""
Write-Host "==== Verificacion despues de la recuperacion ====" -ForegroundColor Cyan
foreach ($target in $targets) {
  if (-not (Check-Target $target)) { $failure += "$($target.Name): continua sin responder completamente" }
}
if ($failure.Count) {
  foreach ($item in $failure) { Write-Warning $item }
  Write-Warning "Si ambos Workers continuan inaccesibles, revisar Cloudflare Workers & Pages > Domains & Routes y el subdominio de cuenta fabricelop.workers.dev."
  exit 1
}
Write-Host "Recuperacion verificada: apps, pagina GAG y APIs responden HTTP 200." -ForegroundColor Green
if (-not $callback.OK) { Write-Warning "tt-control sigue pendiente de comprobacion en Cloudflare." }
