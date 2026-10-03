# Fix-Ejecutar-NewChat-V4.ps1
# Corrige la forma actual de C:\TTiTTulares\Ejecutar.js:
# abrirNuevoChatProyecto puede devolver {ok:false,error:"No encuentro New chat"}.
# En la UI actual de ChatGPT eso no es fatal si ya existe un compositor util en el proyecto.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_NEW_CHAT_OPTIONAL_V4"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }

$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE NEW CHAT OPTIONAL V4" -ForegroundColor Green
  exit 0
}

$oldLf = '    if (!r?.ok)' + "`n" +
  '        throw Error(r?.error || "No se puede crear el chat nuevo.");'
$oldCrLf = '    if (!r?.ok)' + "`r`n" +
  '        throw Error(r?.error || "No se puede crear el chat nuevo.");'

$replacement = '    /* ' + $Marker + ' */' + [Environment]::NewLine +
  '    if (!r?.ok) {' + [Environment]::NewLine +
  '        console.log("AVISO: New chat no visible; se usa el compositor actual del proyecto.");' + [Environment]::NewLine +
  '        return;' + [Environment]::NewLine +
  '    }'

if ($text.Contains($oldCrLf)) {
  $next = $text.Replace($oldCrLf,$replacement)
}
elseif ($text.Contains($oldLf)) {
  $next = $text.Replace($oldLf,$replacement)
}
else {
  throw "No se reconoce el wrapper actual de abrirNuevoChatProyecto; no se modifica Ejecutar.js."
}

foreach ($needle in @(
  'Ejecuta TTiTTulares',
  'Ejecuta TTendencias',
  'TT_CHAT_MESSAGE_B64',
  'const enviar = process.argv.includes("--enviar");',
  'error:"No encuentro New chat"'
)) {
  if (-not $next.Contains($needle)) { throw "Proteccion fallida: falta $needle" }
}

$backup = $Target + ".before-new-chat-v4-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force
Set-Content -LiteralPath $Target -Value $next -Encoding UTF8

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro Node.js para validar Ejecutar.js" }

& $node.Source --check $Target
if ($LASTEXITCODE -ne 0) {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  throw "node --check fallo; Ejecutar.js restaurado desde backup"
}

Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO: NEW CHAT OPTIONAL V4" -ForegroundColor Green
Write-Host "Backup: $backup"
