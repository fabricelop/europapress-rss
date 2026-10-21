# Patch-Ejecutar-ConfirmResponse.ps1
# Corrige C:\TTiTTulares\Ejecutar.js para automatización de ChatGPT:
# 1) "generando:true" confirma que ChatGPT aceptó el envío aunque el contador DOM de usuario tarde;
# 2) una diferencia transitoria al releer el editor no aborta el envío;
# 3) actualiza instalaciones V1 existentes y valida con node --check.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$MarkerV1 = "TT_RESPONSE_CONFIRM_V1"
$MarkerV2 = "TT_RESPONSE_CONFIRM_V2"

if (-not (Test-Path -LiteralPath $Target)) {
  throw "No se encuentra $Target"
}

$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
if ($text.Contains($MarkerV2)) {
  Write-Host "EJECUTAR.JS YA TIENE CONFIRMACION V2" -ForegroundColor Green
  return
}

$backup = $Target + ".before-response-confirm-v2-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  $helperV2 = @'
/* TT_RESPONSE_CONFIRM_V2 */
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

            // En la UI actual de ChatGPT el contador de mensajes del usuario
            // puede actualizarse después de que ya haya empezado la generación.
            // "generando:true" es una confirmación suficiente de que el envío fue aceptado.
            if (
                respuestaIniciada ||
                mensajeAceptado
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
        "ChatGPT no confirmó el inicio de respuesta en 15 s. " +
        detalle
    );
}


'@

  if ($text.Contains($MarkerV1)) {
    $rxHelper = [regex]'(?s)/\* TT_RESPONSE_CONFIRM_V1 \*/.*?(?=async function pulsarEnviar\(evaluar\) \{)'
    $m = $rxHelper.Match($text)
    if (-not $m.Success) {
      throw "Existe TT_RESPONSE_CONFIRM_V1 pero no se pudo localizar su helper."
    }
    $text = $rxHelper.Replace(
      $text,
      [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $helperV2 },
      1
    )
  }
  else {
    $anchor = "async function pulsarEnviar(evaluar) {"
    if (-not $text.Contains($anchor)) {
      throw "No encuentro async function pulsarEnviar(evaluar)"
    }
    $text = $text.Replace($anchor, $helperV2 + $anchor)

    # Si V1 nunca se instaló, añadir usuariosIniciales.
    if ($text -notmatch 'const\s+usuariosIniciales\s*=') {
      $rxAssist = [regex]'const\s+asistentesIniciales\s*=\s*estadoInicial\.asistentes\s*;'
      $matches = $rxAssist.Matches($text)
      if ($matches.Count -ne 1) {
        throw "Esperaba 1 bloque asistentesIniciales y encontré $($matches.Count)"
      }
      $replacement = $matches[0].Value + [Environment]::NewLine + [Environment]::NewLine +
        "        const usuariosIniciales =" + [Environment]::NewLine +
        "            estadoInicial.usuarios;"
      $text = $rxAssist.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $replacement },
        1
      )
    }

    # Si nunca se añadió la llamada de confirmación, añadirla.
    if ($text -notmatch 'esperarInicioRespuesta\s*\(') {
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
      $text = $rxUrl.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $afterUrl },
        1
      )
    }
  }

  # La UI de ChatGPT puede normalizar el contenido del editor (saltos, espacios,
  # nodos contenteditable). No abortar aquí; la confirmación real es que ChatGPT
  # entre en generando/respuesta.
  $text = $text.Replace(
    'throw Error("El mensaje escrito no coincide.");',
    'console.log("AVISO: el editor normalizó el texto; se valida por inicio de respuesta.");'
  )
  $text = $text.Replace(
    "throw Error('El mensaje escrito no coincide.');",
    'console.log("AVISO: el editor normalizó el texto; se valida por inicio de respuesta.");'
  )

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

  Write-Host "EJECUTAR.JS PARCHEADO Y VALIDADO V2" -ForegroundColor Green
  Write-Host "Backup: $backup"
  Write-Host "Nueva condición de éxito: inicio real de respuesta (generando o respuesta creada)."
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH V2 FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}
