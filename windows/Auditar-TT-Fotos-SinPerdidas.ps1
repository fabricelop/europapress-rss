# TT FOTOS - AUDITORIA DE SOLO LECTURA
# No toca Chrome, no envia imagenes, no aprueba, no genera y no modifica archivos.
param([string]$Base = 'C:\TTiTTulares')
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$cutover = [DateTimeOffset]::Parse('2026-11-10T13:33:00.000Z')
$rc = Join-Path $Base 'image-approval-receipts'
if (!(Test-Path -LiteralPath $Base -PathType Container)) { throw "No existe la carpeta: $Base" }

function ReadJsonOrNull([string]$File) {
    try {
        if (!(Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
        return (Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}
function RecordedDate([object]$Task) {
    foreach ($p in @('created_at','requested_at','createdAt','requestedAt','enrolled_at','generated_at')) {
        $v = $Task.PSObject.Properties[$p]
        if ($null -ne $v -and ![string]::IsNullOrWhiteSpace([string]$v.Value)) {
            try { return [DateTimeOffset]::Parse([string]$v.Value) } catch {}
        }
    }
    return $null
}
$statuses = ReadJsonOrNull (Join-Path $rc 'receiver-status.json')
$byCommand = @{}
foreach ($item in @(@('ttendencias','ttendencias-web-images'),@('ttittulares','ttittulares-web-images'))) {
    $project = $item[0]
    $folder = Join-Path $Base $item[1]
    if (!(Test-Path -LiteralPath $folder -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $doc = ReadJsonOrNull $file.FullName
        if ($null -eq $doc) { continue }
        $cmd = [string]$doc.command_id
        if ($cmd -notmatch '^[a-zA-Z0-9_.-]{3,160}$') { continue }
        $event = [string]$doc.target_id
        if ([string]::IsNullOrWhiteSpace($event)) { $event=[string]$doc.event_id }
        if ([string]::IsNullOrWhiteSpace($event)) { $event=[string]$doc.trend_id }
        $when = RecordedDate $doc
        $legacy = ($null -ne $when -and $when -lt $cutover)
        $receipt = ReadJsonOrNull (Join-Path $rc ($cmd+'.json'))
        $received = $false
        if ($null -ne $receipt) {
            $rxCommand = [string]$receipt.commandId
            $rxEvent = [string]$receipt.editorialId
            $received = ($rxCommand -eq $cmd -and $rxEvent -eq $event -and
                [string]$receipt.project -eq $project -and
                [string]$receipt.rasterSHA256 -match '^[a-fA-F0-9]{64}$')
        }
        $hasStaged = (Test-Path -LiteralPath (Join-Path $rc ('immediate-originals\'+$cmd+'.png')) -PathType Leaf)
        $hasCached = (Test-Path -LiteralPath (Join-Path $rc ('original-cache\'+$cmd+'.png')) -PathType Leaf)
        $last = ''
        if ($null -ne $statuses) {
            $status = $statuses.PSObject.Properties[$cmd]
            if ($null -ne $status) { $last = [string]$status.Value.reason }
        }
        $classification = if ($received) { 'RECIBO_LOCAL' }
            elseif ($hasStaged -or $hasCached) { 'ORIGINAL_CONSERVADO_SIN_RECIBO' }
            elseif ($legacy) { 'ANTERIOR_AL_CORTE_SIN_RECIBO' }
            elseif ([string]$doc.status -in @('waiting','needs_review')) { 'SIN_PNG_LOCAL_VERIFICADO' }
            else { 'FUERA_DE_COLA_RECEPCION' }
        $byCommand[$cmd] = [pscustomobject]@{
            Proyecto = $project
            Comando = $cmd
            EditorialID = $event
            Revision = [string]$doc.revision
            EstadoLocal = [string]$doc.status
            Fecha = $(if ($null -ne $when) { $when.ToString('yyyy-MM-dd HH:mm') } else { 'desconocida' })
            Grupo = $classification
            UltimoMotivo = $last
        }
    }
}
$rows = @($byCommand.Values | Sort-Object Fecha -Descending)
$rootReceiptFiles = @(Get-ChildItem -LiteralPath $rc -File -Filter '*.json' -ErrorAction SilentlyContinue)
$receiptCount = 0; $receiptWithoutJob = 0
foreach ($file in $rootReceiptFiles) {
    $r = ReadJsonOrNull $file.FullName
    if ($null -eq $r) { continue }
    if ([string]$r.commandId -notmatch '^[a-zA-Z0-9_.-]{3,160}$' -or [string]$r.rasterSHA256 -notmatch '^[a-fA-F0-9]{64}$') { continue }
    $receiptCount++
    if (!$byCommand.ContainsKey([string]$r.commandId)) { $receiptWithoutJob++ }
}
$stagedNoJob = 0
foreach ($subdir in @('immediate-originals','original-cache')) {
    $dir=Join-Path $rc $subdir
    if (!(Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.png' -ErrorAction SilentlyContinue)) {
        if (!$byCommand.ContainsKey($f.BaseName)) { $stagedNoJob++ }
    }
}
Write-Host ''
Write-Host 'TT_FOTOS_AUDIT SOLO_LECTURA'
Write-Host ('FECHA {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ('TOTAL_INSCRIPCIONES {0}' -f $rows.Count)
Write-Host ('RECIBOS_VALIDOS_FORMATO_LOCAL {0}' -f $receiptCount)
Write-Host ('RECIBOS_SIN_INSCRIPCION_LOCAL {0}' -f $receiptWithoutJob)
Write-Host ('PNG_CONSERVADOS_SIN_INSCRIPCION_LOCAL {0}' -f $stagedNoJob)
Write-Host ('CORTE_HISTORICO_UTC {0}' -f $cutover.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Write-Host ''
$rows | Group-Object Proyecto,Grupo | Sort-Object Name | ForEach-Object {
    Write-Host ('GRUPO {0} = {1}' -f $_.Name,$_.Count)
}
Write-Host ''
Write-Host 'TRABAJOS_SIN_RECIBO_LOCAL:'
$missing = @($rows | Where-Object { $_.Grupo -ne 'RECIBO_LOCAL' })
if ($missing.Count -eq 0) { Write-Host 'NINGUNO_EN_INSCRIPCIONES_LOCALES' }
else {
    $missing | Select-Object -First 100 Proyecto,Comando,EditorialID,Revision,Fecha,Grupo,UltimoMotivo |
        Format-Table -AutoSize -Wrap | Out-String -Width 230 | Write-Host
}
Write-Host ''
Write-Host 'ALCANCE: prueba recepcion local previa, NO acceso actual a bandeja iOS.'
Write-Host 'ALCANCE: una imagen en ChatGPT que nunca se inscribio localmente NO aparece en este informe.'
Write-Host 'ALCANCE: los PNG conservados no se envian ni se modifican mediante este diagnostico.'
