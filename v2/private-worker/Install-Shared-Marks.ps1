# TTActualidad V2 private: install dedicated D1 storage for red marks.
# Never touches V1 or FabCalendar; keeps Worker secrets.
$ErrorActionPreference = "Continue"
$dir = Join-Path $env:TEMP "ttactualidad-v2-private"
if (!(Test-Path (Join-Path $dir ".git"))) { throw "Falta el repositorio local V2" }
Push-Location $dir
try {
  # Redirect native Git chatter to an ordinary text file; Windows PowerShell can misclassify stderr.
  $log = Join-Path $env:TEMP "ttactualidad-v2-git-pull.log"
  & cmd.exe /d /c "git pull --ff-only origin feature/ttactualidad-v2-private-worker-20261114 > $log 2>&1"
  if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar Git; revisa $log" }
  $branch = (& git.exe branch --show-current | Out-String).Trim()
  if ($branch -ne "feature/ttactualidad-v2-private-worker-20261114") { throw "Rama de Git incorrecta" }
  Set-Location (Join-Path $dir "v2\private-worker")
  $cfg = Get-Content ".\wrangler.jsonc" -Raw
  if (!$cfg.Contains('"name": "ttactualidad-v2-private-test"')) { throw "Nombre del Worker inesperado" }
  Write-Host "Comprobando base de datos de V2..."
  $all = & npx.cmd wrangler d1 list --json | Out-String
  if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar D1: $all" }
  $db = @(@($all | ConvertFrom-Json) | Where-Object { $_.name -eq "ttactualidad-v2-marks" })
  if ($db.Count -eq 0) {
    Write-Host "Creando D1 exclusiva de TTActualidad V2..."
    & npx.cmd wrangler d1 create ttactualidad-v2-marks --binding MARKS_DB --update-config
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear D1" }
  } else {
    Write-Host "D1 existente: reutilizandola."
    $conf = Get-Content ".\wrangler.jsonc" -Raw | ConvertFrom-Json
    if (!$conf.d1_databases -or !@($conf.d1_databases | Where-Object { $_.binding -eq "MARKS_DB" }).Count) {
      $conf | Add-Member -NotePropertyName d1_databases -NotePropertyValue @(@{binding="MARKS_DB";database_name="ttactualidad-v2-marks";database_id=$db[0].uuid}) -Force
      $conf | ConvertTo-Json -Depth 12 | Set-Content ".\wrangler.jsonc" -Encoding utf8
    }
  }
  Write-Host "Aplicando esquema de marcas en Cloudflare..."
  & npx.cmd wrangler d1 execute ttactualidad-v2-marks --remote --file .\schema.sql
  if ($LASTEXITCODE -ne 0) { throw "No se pudo inicializar D1" }
  & npm.cmd run build
  if ($LASTEXITCODE -ne 0) { throw "No se pudo compilar V2" }
  & npx.cmd wrangler deploy --keep-vars
  if ($LASTEXITCODE -ne 0) { throw "No se pudo desplegar V2" }
  Write-Host "TT_V2_R_MARKS_REMOTE_READY=YES"
  Write-Host "https://ttactualidad-v2-private-test.fabricelop.workers.dev/"
} finally { Pop-Location }
