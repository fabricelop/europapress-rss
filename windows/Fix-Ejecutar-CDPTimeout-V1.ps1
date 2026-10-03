# Fix-Ejecutar-CDPTimeout-V1.ps1
# Corrige un bloqueo del parche PERSISTENT_PROJECT_CHAT_V1:
# conectar(target) esperaba indefinidamente si un target CDP viejo no abría WebSocket.
# Añade timeout duro de 2s al open y limita el sondeo persistente a 8 candidatos.

$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_CDP_CONNECT_TIMEOUT_V1"

if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }
$text = Get-Content -LiteralPath $Target -Raw -Encoding UTF8
$text = $text -replace "`r`n","`n"

if ($text.Contains($Marker)) {
  Write-Host "EJECUTAR.JS YA TIENE CDP CONNECT TIMEOUT V1" -ForegroundColor Green
  return
}

if (-not $text.Contains("TT_PERSISTENT_PROJECT_CHAT_V1")) {
  throw "Falta TT_PERSISTENT_PROJECT_CHAT_V1"
}

$backup = $Target + ".before-cdp-timeout-v1-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force

try {
  $old = @'
    await new Promise((resolve, reject) => {

        ws.addEventListener(
            "open",
            resolve,
            { once: true }
        );

        ws.addEventListener(
            "error",
            reject,
            { once: true }
        );
    });
'@

  $new = @'
    /* TT_CDP_CONNECT_TIMEOUT_V1 */
    await new Promise((resolve, reject) => {
        let terminado = false;
        const acabar = (err) => {
            if (terminado) return;
            terminado = true;
            clearTimeout(timer);
            if (err) reject(err);
            else resolve();
        };

        const timer = setTimeout(() => {
            try { ws.close(); } catch {}
            acabar(Error("Timeout apertura WebSocket CDP"));
        }, 2000);

        ws.addEventListener(
            "open",
            () => acabar(null),
            { once: true }
        );

        ws.addEventListener(
            "error",
            () => acabar(Error("Error apertura WebSocket CDP")),
            { once: true }
        );
    });
'@

  if (-not $text.Contains($old)) {
    throw "No encuentro bloque de apertura WebSocket esperado"
  }
  $text = $text.Replace($old,$new)

  $oldLoop = "for (const target of paginasProyecto) {"
  $newLoop = "for (const target of paginasProyecto.slice(0,8)) {"
  if (-not $text.Contains($oldLoop)) {
    throw "No encuentro bucle paginasProyecto"
  }
  $text = $text.Replace($oldLoop,$newLoop)

  Set-Content -LiteralPath $Target -Value $text -Encoding UTF8

  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $node) { throw "No encuentro node.exe para validar Ejecutar.js" }
  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) { throw "node --check ha fallado" }

  Write-Host "EJECUTAR.JS PARCHEADO: CDP CONNECT TIMEOUT V1" -ForegroundColor Green
  Write-Host "Backup: $backup"
  Write-Host "WebSocket CDP: timeout 2s; sondeo: max 8 chats."
}
catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "PATCH FALLIDO. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  throw
}