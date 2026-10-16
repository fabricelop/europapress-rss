#requires -Version 5.1
# Hotfix de imagenes TT: el simbolo de remate es SOLO TEXTO, nunca visual.
# No toca Chrome, listeners, tareas, cola, Telegram ni imagenes ya generadas.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\TTiTTulares'
$node = (Get-Command node.exe -ErrorAction SilentlyContinue)
if (!$node) { $node = (Get-Command node -ErrorAction SilentlyContinue) }
if (!$node) { throw 'Node.js no encontrado. Sin cambios.' }
if (!(Test-Path -LiteralPath $root -PathType Container)) {
    throw 'No existe C:\TTiTTulares. Sin cambios.'
}
$changes = @(
    @{
        File='TTiTTularesImageBridge.js'
        Commit='e5a1592b7fb43f23724d1612aca72b7cc99f7b24'
        Markers=@('BRIDGE_FEATURES="v54-submit-generating-transition"','const NO_PEPPER=','PROHIBIDO representar guindillas')
    },
    @{
        File='TTendenciasImageBridge.js'
        Commit='012587eb5a8220fd49a1936d8aeff1979cb0faee'
        Markers=@('BRIDGE_MODE="capture-only-v28-dead-submit-retry"','const NO_PEPPER=','PROHIBIDO representar guindillas')
    }
)
$staged = @()
$backups = @()
Write-Host '=== TT Images: GUINDILLA SOLO EN TEXTO ===' -ForegroundColor Cyan
try {
    foreach($item in $changes){
        $target=Join-Path $root $item.File
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) {
            throw ('Falta bridge local: '+$target+'. Sin cambios.')
        }
        $tmp=Join-Path $root ($item.File+'.no-pepper-new.js')
        $url='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$item.Commit+'/windows/'+$item.File
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -TimeoutSec 50
        $new=[IO.File]::ReadAllText($tmp,[Text.Encoding]::UTF8)
        if ($new.Length -lt 35000) { throw ('Descarga demasiado corta: '+$item.File) }
        foreach($marker in $item.Markers){
            if (!$new.Contains($marker)) { throw ('Falta garantia '+$marker+' en '+$item.File) }
        }
        if ($new.Contains('debe traducir la guindilla')) {
            throw ('Instruccion obsoleta todavia presente: '+$item.File)
        }
        $oldEap=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            & $node.Source --check $tmp 1>$null 2>$null
            $exitCode=$LASTEXITCODE
        } finally { $ErrorActionPreference=$oldEap }
        if ($exitCode -ne 0) { throw ('Error sintaxis Node: '+$item.File) }
        $staged+=@{Item=$item;Target=$target;Temp=$tmp}
        Write-Host ('Validado: '+$item.File)
    }
    foreach($row in $staged){
        $backup=$row.Target+'.before-no-pepper-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
        Copy-Item -LiteralPath $row.Target -Destination $backup -ErrorAction Stop
        $backups+=@{Target=$row.Target;Backup=$backup}
    }
    foreach($row in $staged){
        Move-Item -LiteralPath $row.Temp -Destination $row.Target -Force -ErrorAction Stop
        $content=[IO.File]::ReadAllText($row.Target,[Text.Encoding]::UTF8)
        if (!$content.Contains('PROHIBIDO representar guindillas')) {
            throw ('No se confirma actualizacion: '+$row.Item.File)
        }
    }
    Write-Host 'Confirmado: ambos bridges actualizados con la norma visual.' -ForegroundColor Green
    Write-Host 'Los trabajos que ya estaban generandose conservan su prompt antiguo.'
    Write-Host 'Los siguientes jobs usan el nuevo prompt. Chrome y tareas sin cambios.'
    foreach($row in $backups){Write-Host ('Copia: '+$row.Backup)}
} catch {
    foreach($row in $backups){
        if (Test-Path -LiteralPath $row.Backup) {
            Copy-Item -LiteralPath $row.Backup -Destination $row.Target -Force -ErrorAction SilentlyContinue
        }
    }
    throw
} finally {
    foreach($row in $staged){Remove-Item -LiteralPath $row.Temp -Force -ErrorAction SilentlyContinue}
    foreach($item in $changes){
        $tmp=Join-Path $root ($item.File+'.no-pepper-new.js')
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
