# Fix-Ejecutar-ProjectTarget-V2.ps1
# UI 2026: la portada del proyecto puede no tener compositor y clonar una URL de chat
# en una pestaña nueva puede abrir una vista sin editor. Reutiliza un target del Chrome
# Auto que ya pertenezca al proyecto y tenga un compositor visible.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_PROJECT_TARGET_REUSE_V2"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }
$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
$text = $text -replace "`r`n","`n"

if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE PROJECT TARGET REUSE V2" -ForegroundColor Green
  return
}

if (-not $text.Contains("TT_PROJECT_CHAT_SEED_V1")) {
  throw "Falta TT_PROJECT_CHAT_SEED_V1; ejecuta primero Fix-Ejecutar-ProjectSeed-V1.ps1"
}

$backup = $Target + ".before-project-target-v2-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  $anchor = "async function cerrarPestana(id) {"
  if (-not $text.Contains($anchor)) { throw "No encuentro cerrarPestana(id)" }

  $helper = @'
/* TT_PROJECT_TARGET_REUSE_V2 */
async function targetTieneComposer(target) {

    let conexion = null;

    try {
        conexion = await conectar(target);

        return !!(await conexion.evaluar(`(() => {
            const candidatos = Array.from(
                document.querySelectorAll(
                    '#prompt-textarea,' +
                    '[data-testid="composer-input"],' +
                    '[contenteditable="true"],' +
                    'textarea'
                )
            );

            return candidatos.some(e => {
                const r = e.getBoundingClientRect();
                const s = getComputedStyle(e);

                return (
                    r.width > 0 &&
                    r.height > 0 &&
                    s.display !== "none" &&
                    s.visibility !== "hidden" &&
                    (
                        e.isContentEditable ||
                        e.tagName === "TEXTAREA"
                    )
                );
            });
        })()`));
    }
    catch {
        return false;
    }
    finally {
        try { conexion?.ws?.close(); } catch {}
    }
}


async function obtenerTargetChatSemillaV2() {

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

    const puntuar = t => {
        const titulo = normalizar(t.title);

        if (esImagen) {
            if (
                titulo.includes("generar imagen") ||
                titulo.includes("genera imagen")
            ) return 100;
            return 10;
        }

        if (proyecto === "tendencias") {
            if (titulo.includes("ejecuta ttendencias")) return 100;
            if (titulo.includes("ejecutar pasada editorial")) return 95;
            if (titulo.includes("pasada editorial")) return 90;
            if (!titulo.includes("imagen")) return 20;
            return 0;
        }

        if (titulo.includes("ejecuta ttittulares")) return 100;
        if (titulo.includes("ejecucion de titulares")) return 95;
        if (!titulo.includes("imagen")) return 20;
        return 0;
    };

    paginas.sort((a,b) => puntuar(b) - puntuar(a));

    for (const target of paginas) {
        if (puntuar(target) <= 0) continue;

        if (await targetTieneComposer(target)) {
            console.log(
                "TARGET REUTILIZADO:",
                target.title || "(sin título)",
                target.url
            );
            return target;
        }
    }

    throw Error(
        "No hay ningún chat del proyecto con compositor visible en Chrome Auto."
    );
}


'@

  $text = $text.Replace($anchor, $helper + $anchor)

  $rxMain = [regex]'(?s)const\s+seedUrl\s*=\s*await\s+obtenerUrlChatSemilla\s*\(\s*\)\s*;\s*const\s+target\s*=\s*await\s+crearPestana\s*\(\s*seedUrl\s*\)\s*;'
  $m = $rxMain.Matches($text)
  if ($m.Count -ne 1) {
    throw "Esperaba 1 bloque seedUrl/crearPestana y encontré $($m.Count)"
  }

  $mainReplacement = @'
const target =
        await obtenerTargetChatSemillaV2();

    const targetEsReutilizado = true;
'@

  $text = $rxMain.Replace(
    $text,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $mainReplacement.Trim() },
    1
  )

  $rxClose = [regex]'(?s)if\s*\(\s*!mensajePulsado\s*\|\|\s*terminado\s*\)\s*\{\s*await\s+cerrarPestana\s*\(\s*target\.id\s*\)\s*;\s*\}'
  $mc = $rxClose.Matches($text)
  if ($mc.Count -ne 1) {
    throw "Esperaba 1 bloque final de cerrarPestana y encontré $($mc.Count)"
  }

  $closeReplacement = @'
if (
            !targetEsReutilizado &&
            (
                !mensajePulsado ||
                terminado
            )
        ) {
            await cerrarPestana(
                target.id
            );
        }
'@

  $text = $rxClose.Replace(
    $text,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $closeReplacement.Trim() },
    1
  )

  foreach ($needle in @(
    'TT_NEW_CHAT_OPTIONAL_V4',
    'TT_PROJECT_CHAT_SEED_V1',
    'TT_PROJECT_TARGET_REUSE_V2',
    'TT_CHAT_MESSAGE_B64',
    'Ejecuta TTiTTulares',
    'Ejecuta TTendencias'
  )) {
    if (-not $text.Contains($needle)) { throw "Protección fallida: falta $needle" }
  }

  Set-Content -LiteralPath $Target -Value $text -Encoding UTF8

  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { throw "No encuentro node.exe para validar Ejecutar.js" }

  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) { throw "node --check ha fallado" }

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO: PROJECT TARGET REUSE V2" -ForegroundColor Green
  Write-Host "Backup: $backup"
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH V2 FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
