# Activate private TTActualidad V2 images on this Windows user, once only.
# Requires existing Wrangler Cloudflare login or authorized API token.
# Never touches V1, main, X/Buffer, or any other Cloudflare Worker.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$worker = 'ttactualidad-v2-private-test'
$bucket = 'ttactualidad-v2-images'
$db = 'ttactualidad-v2-marks'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$secretPath = Join-Path $root 'image-ingest-secret.dpapi'
$temp = Join-Path $env:TEMP ('ttv2-image-activate-' + [guid]::NewGuid().ToString('N'))
$repo = 'https://github.com/fabricelop/europapress-rss.git'
$branch = 'feature/ttactualidad-v2-private-worker-20261114'

function Run-Checked([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "$program fallo (exit $LASTEXITCODE)" }
}
foreach ($name in @('git.exe','npm.cmd','npx.cmd','py.exe')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Falta $name" }
}
foreach ($file in @('editorial_run_v2.py','image_same_chat_v2.py','image_intake_v2.py','image_job_v2.py')) {
    if (-not (Test-Path (Join-Path $root $file))) {
        throw "Instala primero el consumidor V2 actualizado: falta $file"
    }
}
if (Test-Path $secretPath) { throw 'Ya existe un secreto DPAPI. No rotar a ciegas ni desincronizar Worker y Windows.' }

try {
    Run-Checked 'git.exe' @('clone','--quiet','--depth','1','--single-branch','--branch',$branch,$repo,$temp)
    $project = Join-Path $temp 'v2\private-worker'
    Push-Location $project
    try {
        Run-Checked 'npm.cmd' @('install','--no-audit','--no-fund')
        Run-Checked 'npm.cmd' @('run','check')
        $rawD1 = (& npx.cmd wrangler d1 list --json | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar D1 Cloudflare' }
        $databases = @($rawD1 | ConvertFrom-Json)
        $match = @($databases | Where-Object { $_.name -eq $db -and $_.uuid })
        if ($match.Count -ne 1) { throw 'No se encontro la D1 aislada de las marcas V2' }
        # R2 must exist BEFORE deployment. Wrangler r2 bucket list does not
        # guarantee JSON output; use r2 bucket info --json (documented).
        $bucketInfo = Join-Path $temp 'bucket-info.json'
        $bucketErrors = Join-Path $temp 'bucket-info-errors.txt'
        $checkBucket = Start-Process -FilePath 'npx.cmd' -ArgumentList @(
            'wrangler','r2','bucket','info',$bucket,'--json') -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $bucketInfo -RedirectStandardError $bucketErrors
        if ($checkBucket.ExitCode -ne 0) {
            # Creation is attempted only on the expected V2 bucket; an auth
            # failure also fails closed here without deploying anything.
            Run-Checked 'npx.cmd' @('wrangler','r2','bucket','create',$bucket)
            $checkBucket = Start-Process -FilePath 'npx.cmd' -ArgumentList @(
                'wrangler','r2','bucket','info',$bucket,'--json') -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $bucketInfo -RedirectStandardError $bucketErrors
        }
        if ($checkBucket.ExitCode -ne 0) { throw 'No se pudo verificar el bucket R2 V2; no desplegar.' }
        $bucketDetails = Get-Content -LiteralPath $bucketInfo -Raw | ConvertFrom-Json
        if ([string]$bucketDetails.name -ne $bucket) {
            throw 'Bucket R2 distinto al esperado. No se despliega.'
        }
        $config = Get-Content -LiteralPath 'wrangler.jsonc' -Raw | ConvertFrom-Json
        if ($config.name -ne $worker) { throw 'Worker inesperado; no desplegar' }
        $config | Add-Member -Force -NotePropertyName 'd1_databases' -NotePropertyValue @(
            [ordered]@{ binding='MARKS_DB'; database_name=$db; database_id=[string]$match[0].uuid })
        $config | Add-Member -Force -NotePropertyName 'r2_buckets' -NotePropertyValue @(
            [ordered]@{ binding='V2_IMAGES'; bucket_name=$bucket })
        [IO.File]::WriteAllText((Join-Path $project 'wrangler.jsonc'),
            ($config | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
        Run-Checked 'npx.cmd' @('wrangler','d1','execute',$db,'--remote','--file','./schema.sql')
        Run-Checked 'npx.cmd' @('wrangler','deploy','--keep-vars')
        # Generate a new high-entropy secret locally, no plaintext secret in GitHub or log.
        $bytes = New-Object byte[] 48
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
        $secret | & npx.cmd wrangler secret put IMAGE_INGEST_SECRET --name $worker | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo guardar secreto en Worker' }
        $cipher = ConvertFrom-SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)
        [IO.File]::WriteAllText($secretPath, $cipher + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
        try {
            $response = Invoke-RestMethod -Method GET -Uri ('https://' + $worker + '.fabricelop.workers.dev/api/image-ingest-ready') -Headers @{'X-TTV2-Image-Ingest'=$secret} -TimeoutSec 20
            if ($response.ok -ne $true -or $response.storage -ne 'ready') {
                throw 'El Worker no confirma R2/D1 listo'
            }
        } catch {
            Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
            throw 'No se verifico preflight remoto. Revisar R2 y secreto sin reenviar imagen.'
        }
        Write-Host 'TT_V2_PRIVATE_IMAGE_STORAGE=READY'
        Write-Host 'TT_V2_IMAGE_DPAPI=ENROLLED'
        Write-Host 'TT_V2_IMAGE_PRECHECK=OK'
        Write-Host 'TT_V2_PUBLISHING=DISABLED'
    } finally { Pop-Location }
} finally {
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue }
}
