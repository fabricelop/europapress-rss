# Despliegue seguro de la única web TTActualidad V2 privada.
# Requiere la sesión existente de Wrangler en este Windows (sin pegar contraseñas).
# No toca main, V1 ni ningún otro Worker.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = 'https://github.com/fabricelop/europapress-rss.git'
$branch = 'feature/ttactualidad-v2-private-worker-20261114'
$worker = 'ttactualidad-v2-private-test'
$database = 'ttactualidad-v2-marks'
$publicUrl = 'https://ttactualidad-v2-private-test.fabricelop.workers.dev'
$work = Join-Path $env:TEMP ('ttv2-deploy-' + [guid]::NewGuid().ToString('N').Substring(0,10))

function Run([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "Falló $program (código $LASTEXITCODE)" }
}

try {
    foreach ($exe in @('git.exe','npm.cmd','npx.cmd')) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "Falta $exe" }
    }
    Write-Host "1/6 Descargando únicamente la rama privada V2..."
    Run 'git.exe' @('clone','--depth','1','--single-branch','--branch',$branch,$repo,$work)
    $dir = Join-Path $work 'v2\private-worker'
    if (-not (Test-Path (Join-Path $dir 'wrangler.jsonc'))) { throw "No se localiza el Worker V2" }
    Push-Location $dir
    try {
        Write-Host "2/6 Validando el Worker y su interfaz..."
        Run 'npm.cmd' @('install','--no-audit','--no-fund')

        # Wrangler usa la sesión Cloudflare que ya está iniciada en este ordenador.
        Write-Host "3/6 Localizando D1 de las marcas R (sin reemplazar su contenido)..."
        $raw = (& npx.cmd wrangler d1 list --json | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar D1 de Cloudflare. Ejecuta npx wrangler login." }
        $entries = @($raw | ConvertFrom-Json)
        $matches = @($entries | Where-Object { $_.name -eq $database })
        if ($matches.Count -ne 1 -or -not $matches[0].uuid) {
            throw "No se encontró una única D1 '$database'. No se despliega para evitar perder las marcas R."
        }
        $settings = Get-Content '.\wrangler.jsonc' -Raw | ConvertFrom-Json
        if ($settings.name -ne $worker) { throw "Worker inesperado: abortando" }
        if ($settings.r2_buckets) { throw "R2 no debe activarse para imagenes V2. Abortando." }
        $id = [string]$matches[0].uuid
        $binding = @([ordered]@{ binding = 'MARKS_DB'; database_name = $database; database_id = $id })
        $settings | Add-Member -Force -NotePropertyName 'd1_databases' -NotePropertyValue $binding
        $settingsJson = $settings | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'wrangler.jsonc'), $settingsJson, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "4/6 Ejecutando las pruebas y compilación..."
        Run 'npm.cmd' @('run','check')
        if (-not (Select-String -Path 'dist\app.js' -SimpleMatch 'function movementIndicator(item)' -Quiet)) {
            throw "La compilación no contiene las flechas de las tendencias"
        }
        if (-not (Select-String -Path 'dist\app.js' -SimpleMatch 'function top30Since(item)' -Quiet)) {
            throw "La compilación no contiene las fechas de entrada"
        }
        if (-not (Select-String -Path 'dist\app.js' -SimpleMatch 'updateRadar(state.captured)' -Quiet)) {
            throw "La compilación no contiene la fecha del Radar"
        }

        Write-Host "5/6 Desplegando solamente $worker (manteniendo secretos y marcas R)..."
        Run 'npx.cmd' @('wrangler','deploy','--keep-vars')

        Write-Host "6/6 Verificando la respuesta pública de salud..."
        $health = Invoke-RestMethod -Method Get -Uri ($publicUrl + '/health') -TimeoutSec 20
        if ($health.ok -ne $true -or $health.service -ne 'ttactualidad-v2-private' -or $health.configured -ne $true -or
            $health.image_storage -ne 'github' -or $health.image_flow -ne 'same-chat' -or
            $health.build -ne 'v2-same-chat-github-20261114') {
            throw "El Worker respondió pero el estado o los secretos no son válidos"
        }
        Write-Host "TT_V2_PRIVATE_DEPLOYED=YES"
        Write-Host "TT_V2_GITHUB_IMAGE_BACKEND=READY"
        Write-Host "TT_V2_R2_REQUIRED=NO"
        Write-Host $publicUrl
        Write-Host "Las flechas y las fechas se verán al recargar la web autenticada."
    } finally { Pop-Location }
} finally {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
