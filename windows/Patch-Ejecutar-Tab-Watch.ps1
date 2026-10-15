# Patch-Ejecutar-Tab-Watch.ps1
# Adds a post-send tab watcher, preserving all editorial/image behavior.
# Idempotent, strict anchors, backup and rollback. Does NOT restart listeners.
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$target=Join-Path $base 'Ejecutar.js'
$monitor=Join-Path $base 'TT-Editorial-Tab-Watch.js'
$source=Join-Path $PSScriptRoot 'TT-Editorial-Tab-Watch.js'
$marker='TT_EDITORIAL_TAB_WATCH_V1'

if(-not (Test-Path -LiteralPath $target)){throw "No existe $target"}
if(-not (Test-Path -LiteralPath $source)){throw "Falta $source; actualiza el repositorio con git pull"}
$node=Get-Command node.exe -ErrorAction Stop
$busy=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -eq 'node.exe' -and [string]$_.CommandLine -match '[\\/]Ejecutar[.]js'
})
if($busy.Count -gt 0){
    Write-Host "PARCHE POSPUESTO: hay $($busy.Count) Ejecutar.js activo(s); no modificar archivos durante un envio." -ForegroundColor Yellow
    exit 2
}
$text=[IO.File]::ReadAllText($target,[Text.Encoding]::UTF8)
if(-not $text.Contains('TT_PROJECT_LANDING_COMPOSER_V2') -or -not $text.Contains('TT_RESPONSE_CONFIRM_V2')){
    throw 'Version no reconocida de Ejecutar.js: no se modifica.'
}
# Match the stable ASCII launch marker, regardless of whether the local file
# stores accented characters as UTF-8, ANSI or already-misdecoded text.
# Do not match other console.log calls, and require exactly one occurrence.
$rx=[regex]'(?m)([ \t]*console\.log\(\s*"EJECUCION LANZADA\.[^"\r\n]*"\s*\);)'
if(-not $text.Contains($marker)){
    $hits=$rx.Matches($text)
    if($hits.Count -ne 1){throw "Marcador de lanzamiento inesperado (coincidencias=$($hits.Count)); no se modifica."}
}
$originalCount=([regex]::Matches($text,[regex]::Escape($marker))).Count
if($originalCount -gt 1){throw 'Multiples parches de seguimiento detectados; no se modifica.'}
$watcher=[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)
if(-not $watcher.Contains($marker)){throw 'El watcher no contiene el marcador de version esperado.'}
# Syntax check the downloaded watcher before touching the installed files.
$oldPref=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & $node.Source --check $source 1>$null 2>$null
    $code=$LASTEXITCODE
} finally {$ErrorActionPreference=$oldPref}
if($code -ne 0){throw 'El monitor JS no supera node --check.'}

Write-Host "`n=== EJECUTAR.JS ==="
Write-Host "Seguimiento instalado: $($text.Contains($marker))"
Write-Host "Monitor de origen validado: True"
Write-Host "Sin procesos Ejecutar.js activos: True"
if($CheckOnly){Write-Host 'Solo comprobacion; no se ha modificado nada.';return}

$append=@'
        
        /* TT_EDITORIAL_TAB_WATCH_V1 */
        // La conversación ya fue confirmada. Supervisar esta pestaña temporal
        // sin esperar al final de ChatGPT ni bloquear el trabajo siguiente.
        try {
            const fsWatcher = await import("node:fs");
            const { spawn: startWatcher } = await import("node:child_process");
            const watcherPath = "C:\\TTiTTulares\\TT-Editorial-Tab-Watch.js";
            if (fsWatcher.existsSync(watcherPath)) {
                const monitor = startWatcher(
                    process.execPath,
                    [watcherPath, "--register", String(target.id), String(nuevaUrl)],
                    { detached: true, stdio: "ignore", windowsHide: true }
                );
                monitor.unref();
                console.log("SEGUIMIENTO PESTANA TEMPORAL:", String(target.id).slice(0, 16));
            } else {
                console.log("AVISO: monitor de pestanas no disponible. La conversacion queda abierta.");
            }
        } catch (watchError) {
            console.log("AVISO: no se pudo iniciar monitor; se conserva el chat:",
                String(watchError && watchError.message || watchError));
        }

'@
$newText=$text
if(-not $text.Contains($marker)){
    $newText=$rx.Replace($text,[System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $m.Value+$append
    },1)
    if(-not $newText.Contains($marker)){throw 'No se inserto el marcador del parche.'}
}
$backup=$target+'.before-tab-watch-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
$monitorBackup=$null
Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
if(Test-Path -LiteralPath $monitor){
    $monitorBackup=$monitor+'.before-tab-watch-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
    Copy-Item -LiteralPath $monitor -Destination $monitorBackup -ErrorAction Stop
}
try {
    $tmpMonitor=$monitor+'.tmp.js'
    Copy-Item -LiteralPath $source -Destination $tmpMonitor -Force
    # Prevent a newly starting runner from seeing a half-written watcher.
    Move-Item -LiteralPath $tmpMonitor -Destination $monitor -Force
    if($newText -ne $text){
        # UTF-8 without BOM to preserve JavaScript source compatibility.
        $utf8=New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($target,$newText,$utf8)
    }
    $oldPref=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        & $node.Source --check $target 1>$null 2>$null
        $exit=$LASTEXITCODE
    }finally{$ErrorActionPreference=$oldPref}
    if($exit -ne 0){throw 'Ejecutar.js no supera node --check tras instalar.'}
    Write-Host 'EJECUTAR.JS ACTUALIZADO Y VALIDADO' -ForegroundColor Green
    Write-Host "Monitor: $monitor"
    Write-Host "Backup Ejecutar.js: $backup"
    if($monitorBackup){Write-Host "Backup monitor: $monitorBackup"}
    Write-Host 'No se ha reiniciado Chrome, imagenes ni listeners.'
} catch {
    Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
    if($monitorBackup){Copy-Item -LiteralPath $monitorBackup -Destination $monitor -Force -ErrorAction SilentlyContinue}
    else{Remove-Item -LiteralPath $monitor -Force -ErrorAction SilentlyContinue}
    Write-Host 'ERROR: Ejecutar.js restaurado desde el backup.' -ForegroundColor Red
    throw
}
