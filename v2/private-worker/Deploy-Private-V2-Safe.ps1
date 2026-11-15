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

# Windows PowerShell 5.1 reports NORMAL native stderr progress (for example
# git: "Cloning into...") as NativeCommandError when ErrorActionPreference=Stop.
# Use the REAL process exit code, keeping separate output streams and rejecting
# only actual non-zero exits. This applies equally to npm and Wrangler.
function Run([string]$program, [string[]]$arguments, [switch]$CaptureOutput) {
    $marker = [guid]::NewGuid().ToString('N')
    $stdout = Join-Path $env:TEMP ('ttv2-deploy-' + $marker + '.stdout.log')
    $stderr = Join-Path $env:TEMP ('ttv2-deploy-' + $marker + '.stderr.log')
    $escapedArgs = @($arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_.Replace('"','\"')) + '"' } else { $_ }
    })
    try {
        $process = Start-Process -FilePath $program -ArgumentList ($escapedArgs -join ' ') `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $out = if (Test-Path -LiteralPath $stdout) {
            [System.IO.File]::ReadAllText($stdout, [System.Text.Encoding]::UTF8)
        } else { '' }
        $err = if (Test-Path -LiteralPath $stderr) {
            [System.IO.File]::ReadAllText($stderr, [System.Text.Encoding]::UTF8)
        } else { '' }
        if ($process.ExitCode -ne 0) {
            if ($out.Trim()) { Write-Host $out.TrimEnd() }
            if ($err.Trim()) { Write-Host $err.TrimEnd() }
            throw ("TT_V2_NATIVE_EXIT_CODE={0}; programa={1}" -f $process.ExitCode, $program)
        }
        if ($CaptureOutput) {
            return $out
        }
        if ($out.Trim()) { Write-Host $out.TrimEnd() }
        if ($err.Trim()) { Write-Host $err.TrimEnd() }
    }
    finally {
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
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
        # This exact existing D1 was verified through Cloudflare D1 list + info.
        # Do not infer the binding ID from PowerShell's parsing of a CLI JSON array:
        # a false negative on Windows PowerShell 5.1 blocked the last safe deploy.
        $expectedDbId = 'bc11570d-5f1e-40cc-9692-861e7103eca2'
        # Remote read-only existence check. Wrangler fails nonzero if D1 is unavailable.
        Run 'npx.cmd' @('wrangler','d1','info',$database,'--json') -CaptureOutput | Out-Null
        $settings = Get-Content '.\wrangler.jsonc' -Raw | ConvertFrom-Json
        if ($settings.name -ne $worker) { throw "Worker inesperado: abortando" }
        if ($settings.PSObject.Properties["r2_buckets"] -and $settings.r2_buckets) { throw "R2 no debe activarse para imagenes V2. Abortando." }
        $bindings = @($settings.d1_databases)
        if ($bindings.Count -ne 1 -or $bindings[0].binding -ne 'MARKS_DB' -or
            $bindings[0].database_name -ne $database -or ([string]$bindings[0].database_id) -ne $expectedDbId) {
            throw "El binding MARKS_DB del Worker no coincide con la D1 verificada. No se despliega."
        }
        Write-Host "TT_V2_D1_BINDING_CONFIG_VERIFIED=YES"

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
