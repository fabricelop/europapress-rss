# Fix-Ejecutar-ProjectSeed-V1.ps1
# Evita abrir la portada del proyecto (sin compositor en la UI actual).
# En su lugar descubre un chat semilla ya existente dentro del proyecto y abre una copia
# de esa URL para la ejecución. Mantiene separados, en lo posible, editorial e imágenes.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_PROJECT_CHAT_SEED_V1"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }
$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8

if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE PROJECT CHAT SEED V1" -ForegroundColor Green
  return
}

$backup = $Target + ".before-project-seed-v1-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  $anchor = @'
async function cerrarPestana(id) {
'@
  if (-not $text.Contains($anchor)) {
    throw "No encuentro async function cerrarPestana(id)"
  }

  $helper = @'
/* TT_PROJECT_CHAT_SEED_V1 */
async function obtenerUrlChatSemilla() {

    const r = await fetch(
        `${BASE_CDP}/json/list?t=${Date.now()}`
    );

    if (!r.ok)
        throw Error("No se puede leer la lista de pestañas de Chrome Auto.");

    const targets = await r.json();

    const paginas = targets.filter(t =>
        t &&
        t.type === "page" &&
        typeof t.url === "string" &&
        t.url.startsWith(PROJECT_URL + "/c/") &&
        t.webSocketDebuggerUrl
    );

    const normalizar = s =>
        String(s || "")
            .normalize("NFD")
            .replace(/[\u0300-\u036f]/g, "")
            .toLowerCase();

    const esImagen =
        /^TT(?:ITTULARES)?_IMAGE_JOB_V3\b/.test(mensaje);

    let elegida = null;

    if (esImagen) {
        elegida = paginas.find(t => {
            const titulo = normalizar(t.title);
            return (
                titulo.includes("generar imagen") ||
                titulo.includes("genera imagen")
            );
        });
    }
    else if (proyecto === "tendencias") {
        elegida = paginas.find(t => {
            const titulo = normalizar(t.title);
            return (
                titulo.includes("ejecuta ttendencias") ||
                titulo.includes("ejecutar pasada editorial") ||
                titulo.includes("pasada editorial")
            );
        });
    }
    else {
        elegida = paginas.find(t => {
            const titulo = normalizar(t.title);
            return (
                titulo.includes("ejecuta ttittulares") ||
                titulo.includes("ejecucion de titulares")
            );
        });
    }

    if (!elegida) {
        elegida = paginas.find(t => {
            const titulo = normalizar(t.title);
            return !titulo.includes("imagen");
        });
    }

    if (!elegida)
        elegida = paginas[0];

    if (!elegida)
        throw Error(
            "No hay ningún chat existente del proyecto que pueda usarse como semilla."
        );

    console.log(
        "CHAT SEMILLA:",
        elegida.title || "(sin título)",
        elegida.url
    );

    return elegida.url;
}


'@

  $text = $text.Replace($anchor, $helper + $anchor)

  $old = @'
    /*
     * CADA EJECUCION EMPIEZA
     * EN UN CHAT NUEVO DEL PROYECTO.
     */
    const target =
        await crearPestana(
            PROJECT_URL
        );
'@

  $new = @'
    /*
     * La portada del proyecto ya no expone siempre un compositor.
     * Abrimos una copia de un chat semilla existente dentro del proyecto.
     * El flujo posterior intenta New chat y, si no está visible, usa
     * directamente el compositor de esa conversación.
     */
    const seedUrl =
        await obtenerUrlChatSemilla();

    const target =
        await crearPestana(
            seedUrl
        );
'@

  if (-not $text.Contains($old)) {
    throw "No encuentro el bloque main que abre PROJECT_URL"
  }

  $text = $text.Replace($old,$new)

  foreach ($needle in @(
    'TT_NEW_CHAT_OPTIONAL_V4',
    'TT_CHAT_MESSAGE_B64',
    'Ejecuta TTiTTulares',
    'Ejecuta TTendencias',
    'const enviar = process.argv.includes("--enviar");'
  )) {
    if (-not $text.Contains($needle)) {
      throw "Protección fallida: falta $needle"
    }
  }

  Set-Content -LiteralPath $Target -Value $text -Encoding UTF8

  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { throw "No encuentro node.exe para validar Ejecutar.js" }

  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) {
    throw "node --check ha fallado"
  }

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO: PROJECT CHAT SEED V1" -ForegroundColor Green
  Write-Host "Backup: $backup"
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
