# Fix-Ejecutar-PersistentProjectChat-V1.ps1
# Parche mínimo para la UI actual de ChatGPT:
# - no abre la portada del proyecto;
# - no depende del botón "New chat";
# - reutiliza un chat YA abierto dentro de PROYECTOS APP que tenga compositor visible.
# Recovery y listeners NO aplican este parche automáticamente.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_PERSISTENT_PROJECT_CHAT_V1"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }

$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
$text = $text -replace "`r`n","`n"

if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE PERSISTENT PROJECT CHAT V1" -ForegroundColor Green
  return
}

foreach ($forbidden in @(
  "TT_NEW_CHAT_OPTIONAL_V4",
  "TT_PROJECT_CHAT_SEED_V1",
  "TT_PROJECT_TARGET_REUSE_V2"
)) {
  if ($text.Contains($forbidden)) {
    throw "Ejecutar.js no está en la base limpia: contiene $forbidden"
  }
}

$backup = $Target + ".before-persistent-project-chat-v1-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  $anchor = "async function obtenerEstado(evaluar) {"
  if (-not $text.Contains($anchor)) {
    throw "No encuentro obtenerEstado(evaluar)"
  }

  $helper = @'
/* TT_PERSISTENT_PROJECT_CHAT_V1 */
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


async function obtenerTargetPersistenteProyecto() {
    const r = await fetch(
        `${BASE_CDP}/json/list?t=${Date.now()}`
    );

    if (!r.ok)
        throw Error("No se puede leer la lista de pestañas de Chrome Auto.");

    const targets = await r.json();

    const paginasProyecto = targets.filter(t =>
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

    function puntuacion(t) {
        const titulo = normalizar(t.title);

        if (esImagen) {
            if (
                titulo.includes("generar imagen") ||
                titulo.includes("genera imagen")
            ) return 100;
            return 5;
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
    }

    paginasProyecto.sort(
        (a,b) => puntuacion(b) - puntuacion(a)
    );

    for (const target of paginasProyecto) {
        if (puntuacion(target) <= 0)
            continue;

        if (await targetTieneComposer(target)) {
            console.log(
                "CHAT PERSISTENTE:",
                target.title || "(sin título)",
                target.url
            );
            return target;
        }
    }

    throw Error(
        "No hay ningún chat abierto del proyecto con compositor visible."
    );
}


'@

  $text = $text.Replace($anchor, $helper + $anchor)

  $rxTarget = [regex]'(?s)const\s+target\s*=\s*await\s+crearPestana\s*\(\s*PROJECT_URL\s*\)\s*;'
  $mTarget = $rxTarget.Matches($text)
  if ($mTarget.Count -ne 1) {
    throw "Esperaba 1 apertura de PROJECT_URL y encontré $($mTarget.Count)"
  }

  $text = $rxTarget.Replace(
    $text,
    [System.Text.RegularExpressions.MatchEvaluator]{
      param($m)
      'const target =' + "`n" +
      '        await obtenerTargetPersistenteProyecto();' + "`n`n" +
      '    const targetPersistente = true;'
    },
    1
  )

  $rxNewChatCall = [regex]'await\s+abrirNuevoChatProyecto\s*\(\s*evaluar\s*\)\s*;'
  $mNewChat = $rxNewChatCall.Matches($text)
  if ($mNewChat.Count -ne 1) {
    throw "Esperaba 1 llamada a abrirNuevoChatProyecto y encontré $($mNewChat.Count)"
  }

  $text = $rxNewChatCall.Replace(
    $text,
    'console.log("Usando chat persistente del proyecto; no se crea New chat.");',
    1
  )

  $rxClose = [regex]'await\s+cerrarPestana\s*\(\s*target\.id\s*\)\s*;'
  $mClose = $rxClose.Matches($text)
  if ($mClose.Count -ne 1) {
    throw "Esperaba 1 cierre de target principal y encontré $($mClose.Count)"
  }

  $text = $rxClose.Replace(
    $text,
    'if (!targetPersistente) await cerrarPestana(target.id);',
    1
  )

  foreach ($needle in @(
    "TT_PERSISTENT_PROJECT_CHAT_V1",
    "TT_RESPONSE_CONFIRM_V2",
    "TT_CHAT_MESSAGE_B64",
    "Ejecuta TTiTTulares",
    "Ejecuta TTendencias"
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

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO: PERSISTENT PROJECT CHAT V1" -ForegroundColor Green
  Write-Host "Backup: $backup"
  Write-Host "No depende de New chat; reutiliza un chat del proyecto con compositor visible."
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
