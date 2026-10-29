#requires -Version 5.1
# Safe, one-file deployment of TTiTTulares ChatGPT composer repair.
# No Chrome restart, no task edits, no listener or TTendencias/TTImages changes.
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root='C:\TTiTTulares'
$target=Join-Path $root 'TTiTTularesImageBridge.js'
if(-not (Test-Path -LiteralPath $target)){throw 'Puente TTiTTulares no instalado. Sin cambios.'}
$node=Get-Command node.exe -ErrorAction SilentlyContinue
if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
if(-not $node){throw 'Node.js no disponible. Sin cambios.'}
$running=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
    $_.Name -match '^node(\.exe)?$' -and [string]$_.CommandLine -like '*TTiTTularesImageBridge.js*'
})
if($running.Count){throw 'Hay una generación TTiTTulares en curso. No se cambia el archivo; reintentar cuando termine.'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('tt-composer-'+[guid]::NewGuid().ToString('N')+'.js')
try {
    $commit=Invoke-RestMethod -Uri 'https://api.github.com/repos/fabricelop/europapress-rss/commits/main' -TimeoutSec 15 -Headers @{
        'User-Agent'='TTiTTulares-composer-safe-fix';'Accept'='application/vnd.github+json'
    }
    $sha=[string]$commit.sha
    if($sha -notmatch '^[a-f0-9]{40}$'){throw 'No se pudo fijar una revisión de GitHub'}
    $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/windows/TTiTTularesImageBridge.js'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temp -TimeoutSec 35 -Headers @{
        'User-Agent'='TTiTTulares-composer-safe-fix';'Cache-Control'='no-cache'
    }
    $src=[IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
    foreach($marker in @('async function ensureVisibleComposerBeforeInput(',
        'await ensureVisibleComposerBeforeInput(cdp);',
        'BRIDGE VISIBLE COMPOSER RECOVERY',
        'BRIDGE ATOMIC PROMPT VERIFIED AND SENT',
        'if(!launchOnly)throw Error("legacy_raster_mode_disabled_request_launch_only_job")',
        'await confirmPromptLaunched()')){
        if(-not $src.Contains($marker)){throw ('Puente remoto sin corrección segura: '+$marker)}
    }
    & $node.Source --check $temp
    if($LASTEXITCODE -ne 0){throw 'Puente remoto con sintaxis JavaScript inválida'}
    $localHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $newHash=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    Write-Host ('Comprobación bridge TTiTTulares: '+$(if($localHash -eq $newHash){'ACTUALIZADO'}else{'CAMBIO PENDIENTE'}))
    Write-Host ('GitHub commit: '+$sha)
    if($CheckOnly){Write-Host 'Modo lectura: no se ha cambiado nada';return}
    if($localHash -eq $newHash){Write-Host 'Ya instalado. Sin cambios.';return}
    # Prevent replacing the source file while a new child bridge is executing.
    $active=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
        $_.Name -match '^node(\.exe)?$' -and [string]$_.CommandLine -like '*TTiTTularesImageBridge.js*'
    })
    if($active.Count){throw 'El bridge se ha iniciado mientras se verificaba. Sin cambios.'}
    $backup=$target+'.before-composer-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
    Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
    try{
        Copy-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $newHash){
            throw 'No coincide el SHA256 tras instalar el puente'
        }
    }catch{
        Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
        throw
    }
    Write-Host 'Puente TTiTTulares actualizado. El siguiente trabajo utiliza el nuevo código.' -ForegroundColor Green
    Write-Host ('Copia previa: '+$backup)
    Write-Host 'Chrome, TTendencias, TTImages, listeners, Workers e iPhone no modificados.'
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
