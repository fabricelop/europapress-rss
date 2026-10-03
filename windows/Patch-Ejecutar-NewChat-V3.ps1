# Patch-Ejecutar-NewChat-V3.ps1
# Hotfix local para C:\TTiTTulares\Ejecutar.js.
# La UI de ChatGPT puede abrir ya un chat/compositor dentro del proyecto y no mostrar "New chat".
# En ese caso no debe abortar: se continua sobre el compositor existente.
# No cambia mensajes titulares/tendencias ni la logica editorial/imagen.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_NEW_CHAT_OPTIONAL_V3"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }
$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE NEW CHAT OPTIONAL V3" -ForegroundColor Green
  exit 0
}

$backup = $Target + ".before-new-chat-v3-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  # Caso habitual: if (!x) throw Error("No encuentro New chat"); seguido de click sobre x.
  # Sustituimos SOLO el throw. Si no existe el boton, fabricamos un objeto con click no-op;
  # el flujo posterior continua y la validacion del compositor/envio decide si la pagina sirve.
  $rx = [regex]'(?m)^(?<indent>\s*)if\s*\(\s*!\s*(?<var>[A-Za-z_$][A-Za-z0-9_$]*)\s*\)\s*(?:\{\s*)?throw\s+(?:new\s+)?Error\(\s*(["''])No encuentro New chat\3\s*\)\s*;?\s*(?:\}\s*)?$'
  $m = $rx.Match($text)
  if (-not $m.Success) {
    # Variante con mensaje ampliado, manteniendo la misma garantia de variable.
    $rx = [regex]'(?m)^(?<indent>\s*)if\s*\(\s*!\s*(?<var>[A-Za-z_$][A-Za-z0-9_$]*)\s*\)\s*(?:\{\s*)?throw\s+(?:new\s+)?Error\(\s*(["''])No encuentro New chat[^"'']*\3\s*\)\s*;?\s*(?:\}\s*)?$'
    $m = $rx.Match($text)
  }
  if (-not $m.Success) {
    throw "No se reconoce el bloque que produce 'No encuentro New chat'; no se ha modificado Ejecutar.js."
  }

  $indent = $m.Groups['indent'].Value
  $var = $m.Groups['var'].Value
  $replacement = $indent + '/* ' + $Marker + ' */' + [Environment]::NewLine +
    $indent + 'if (!' + $var + ') {' + [Environment]::NewLine +
    $indent + '    console.log("AVISO: New chat no visible; se prueba el compositor actual del proyecto.");' + [Environment]::NewLine +
    $indent + '    ' + $var + ' = { click: async () => {} };' + [Environment]::NewLine +
    $indent + '}'

  $next = $text.Substring(0,$m.Index) + $replacement + $text.Substring($m.Index + $m.Length)

  # Protecciones: no tocar comandos ni soporte de mensajes de ninguno de los dos productos.
  foreach ($needle in @(
    'Ejecuta TTiTTulares',
    'Ejecuta TTendencias',
    'TT_CHAT_MESSAGE_B64',
    'const enviar = process.argv.includes("--enviar");'
  )) {
    if (-not $next.Contains($needle)) { throw "Proteccion fallida: falta $needle" }
  }

  Set-Content -LiteralPath $Target -Value $next -Encoding UTF8
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { throw "No encuentro node.exe para validar Ejecutar.js" }
  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) { throw "node --check ha fallado" }

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO: NEW CHAT OPTIONAL V3" -ForegroundColor Green
  Write-Host "Si ChatGPT ya muestra compositor dentro del proyecto, continua sin exigir el boton New chat."
  Write-Host "Si no hay compositor util, las comprobaciones posteriores seguiran fallando de forma segura."
  Write-Host "Backup: $backup"
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
