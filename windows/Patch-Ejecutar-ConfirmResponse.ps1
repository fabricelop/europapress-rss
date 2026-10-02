# Patch-Ejecutar-ConfirmResponse.ps1
# Refuerza C:\TTiTTulares\Ejecutar.js:
# 1) no considera enviado un mensaje solo porque aparezca una URL /c/;
# 2) exige que el mensaje del usuario aparezca y que ChatGPT empiece a responder;
# 3) es idempotente y restaura backup si node --check falla.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_RESPONSE_CONFIRM_V1"

if (-not (Test-Path -LiteralPath $Target)) {
  throw "No se encuentra $Target"
}

$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE CONFIRMACION DE RESPUESTA" -ForegroundColor Green
  exit 0
}

$backup = $Target + ".before-response-confirm-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  # A) Insertar helper antes de pulsarEnviar.
  $anchor = "async function pulsarEnviar(evaluar) {"
  if (-not $text.Contains($anchor)) {
    throw "No encuentro async function pulsarEnviar(evaluar)"
  }

  $helper = @'
/* TT_RESPONSE_CONFIRM_V1 */
async function esperarInicioRespuesta(
    evaluar,
    usuariosIniciales,
    asistentesIniciales,
    timeoutMs = 15000
) {
    const limite = Date.now() + timeoutMs;
    let ultimo = null;

    while (Date.now() < limite) {
        try {
            ultimo = await obtenerEstado(evaluar);

            const usuarios =
                Number(ultimo?.usuarios || 0);

            const asistentes =
                Number(ultimo?.asistentes || 0);

            const mensajeAceptado =
                usuarios > Number(usuariosIniciales || 0);

            const respuestaIniciada =
                !!ultimo?.generando ||
                asistentes > Number(asistentesIniciales || 0);

            if (
                mensajeAceptado &&
                respuestaIniciada
            ) {
                return ultimo;
            }
        }
        catch {}

        await sleep(250);
    }

    const detalle = ultimo
        ? JSON.stringify({
            usuarios: ultimo.usuarios,
            asistentes: ultimo.asistentes,
            generando: ultimo.generando,
            url: ultimo.url
          })
        : "sin estado";

    throw Error(
        "ChatGPT no confirmó el mensaje y el inicio de respuesta en 15 s. " +
        detalle
    );
}


'@

  $text = $text.Replace($anchor, $helper + $anchor)

  # B) Guardar también el número inicial de mensajes de usuario.
  $rxAssist = [regex]'const\s+asistentesIniciales\s*=\s*estadoInicial\.asistentes\s*;'
  $matches = $rxAssist.Matches($text)
  if ($matches.Count -ne 1) {
    throw "Esperaba 1 bloque asistentesIniciales y encontré $($matches.Count)"
  }
  $replacement = $matches[0].Value + [Environment]::NewLine + [Environment]::NewLine +
    "        const usuariosIniciales =" + [Environment]::NewLine +
    "            estadoInicial.usuarios;"
  $text = $rxAssist.Replace($text, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)

  # C) Tras crear la URL real, esperar aceptación del mensaje + inicio de respuesta.
  $rxUrl = [regex]'(?s)(const\s+nuevaUrl\s*=\s*await\s+esperarUrlReal\s*\(\s*evaluar\s*\)\s*;)'
  $urlMatches = $rxUrl.Matches($text)
  if ($urlMatches.Count -ne 1) {
    throw "Esperaba 1 bloque esperarUrlReal y encontré $($urlMatches.Count)"
  }
  $afterUrl = $urlMatches[0].Value + [Environment]::NewLine + [Environment]::NewLine +
    "        await esperarInicioRespuesta(" + [Environment]::NewLine +
    "            evaluar," + [Environment]::NewLine +
    "            usuariosIniciales," + [Environment]::NewLine +
    "            asistentesIniciales," + [Environment]::NewLine +
    "            15000" + [Environment]::NewLine +
    "        );"
  $text = $rxUrl.Replace($text, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $afterUrl }, 1)

  Set-Content -LiteralPath $Target -Value $text -Encoding UTF8

  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) {
    throw "No encuentro node.exe para validar Ejecutar.js"
  }

  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) {
    throw "node --check ha fallado"
  }

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO" -ForegroundColor Green
  Write-Host "Backup: $backup"
  Write-Host "Nueva condición de éxito: mensaje aceptado + respuesta iniciada."
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
