$ErrorActionPreference = "Stop"
$Target = "C:\TTiTTulares\Ejecutar.js"
$Marker = "TT_PROJECT_LANDING_COMPOSER_V2"
if (-not (Test-Path -LiteralPath $Target)) { throw "No se encuentra $Target" }
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw "No encuentro node.exe" }
$text = (Get-Content -LiteralPath $Target -Raw -Encoding UTF8) -replace "`r`n","`n"
if ($text.Contains($Marker)) {
  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) { throw "Ejecutar.js V2 no supera node --check" }
  Write-Host "EJECUTAR.JS YA TIENE PROJECT LANDING COMPOSER V2" -ForegroundColor Green
  return
}
$backup = $Target + ".before-project-landing-v2-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
Copy-Item -LiteralPath $Target -Destination $backup -Force
try {
  $rxPersistent = [regex]'(?s)/\* TT_PERSISTENT_PROJECT_CHAT_V1 \*/.*?(?=async function obtenerEstado\(evaluar\) \{)'
  if ($rxPersistent.Matches($text).Count -gt 1) { throw "Mas de un bloque persistent V1" }
  $text = $rxPersistent.Replace($text,"",1)
  $rxOldNewChat = [regex]'(?s)async function abrirNuevoChatProyecto\(evaluar\) \{.*?(?=// ============================================================\n// MAIN)'
  if ($rxOldNewChat.Matches($text).Count -ne 1) { throw "No hay una unica funcion abrirNuevoChatProyecto" }
  $text = $rxOldNewChat.Replace($text,"",1)
  $newTarget = @'
/* TT_PROJECT_LANDING_COMPOSER_V2 */
    const target =
        await crearPestana(
            PROJECT_URL
        );

    const targetPersistente = false;
'@
  $rxPersistentTarget = [regex]'(?s)const\s+target\s*=\s*await\s+obtenerTargetPersistenteProyecto\(\)\s*;\s*const\s+targetPersistente\s*=\s*true\s*;'
  $rxCleanTarget = [regex]'(?s)const\s+target\s*=\s*await\s+crearPestana\s*\(\s*PROJECT_URL\s*\)\s*;'
  if ($rxPersistentTarget.Matches($text).Count -eq 1) {
    $text = $rxPersistentTarget.Replace($text,$newTarget,1)
  } elseif ($rxCleanTarget.Matches($text).Count -eq 1) {
    $text = $rxCleanTarget.Replace($text,$newTarget,1)
  } else { throw "No encuentro un bloque de target compatible" }
  $newLandingCheck = @'
const estadoInicial =
            await esperarComposer(
                evaluar,
                45000
            );

        const projectLanding = await evaluar(
            "(() => {" +
            "const editor=document.querySelector('[role=\"textbox\"][contenteditable=\"true\"][aria-label^=\"New chat in \"]');" +
            "const rect=editor?.getBoundingClientRect();" +
            "const style=editor?getComputedStyle(editor):null;" +
            "const visible=!!editor&&rect.width>0&&rect.height>0&&style.display!==\"none\"&&style.visibility!==\"hidden\";" +
            "return {ok:visible&&location.pathname.endsWith(\"/project\"),url:location.href,ariaLabel:editor?.getAttribute(\"aria-label\")||null};" +
            "})()"
        );

        if (!projectLanding?.ok) {
            throw Error("La portada del proyecto no muestra su compositor. " +
                JSON.stringify(projectLanding || {}));
        }
        console.log("COMPOSITOR DEL PROYECTO:",
            projectLanding.ariaLabel, projectLanding.url);
'@
  $rxInitialState = [regex]'(?s)let\s+estadoInicial;\s*try\s*\{.*?console\.log\(\s*"Proyecto abierto correctamente\."\s*\);'
  if ($rxInitialState.Matches($text).Count -ne 1) { throw "No hay un unico bloque de apertura inicial" }
  $text = $rxInitialState.Replace($text,$newLandingCheck,1)
  $genericSelector = "'#prompt-textarea,' +"
  $observedSelector = "'[role=`"textbox`"][contenteditable=`"true`"][aria-label^=`"New chat in `"],' +"
  if (-not $text.Contains($observedSelector)) {
    if (-not $text.Contains($genericSelector)) { throw "No encuentro selectores de compositor" }
    $text = $text.Replace($genericSelector,$observedSelector + "`n                    " + $genericSelector)
  }
  if ($text -match 'TT_PERSISTENT_PROJECT_CHAT_V1|obtenerTargetPersistenteProyecto|abrirNuevoChatProyecto') {
    throw "Persisten restos de parches incompatibles"
  }
  foreach ($needle in @($Marker,'location.pathname.endsWith(\"/project\")',
    '[aria-label^="New chat in "]','TT_RESPONSE_CONFIRM_V2','TT_CHAT_MESSAGE_B64')) {
    if (-not $text.Contains($needle)) { throw "Falta garantia: $needle" }
  }
  Set-Content -LiteralPath $Target -Value $text -Encoding UTF8
  & $node.Source --check $Target
  if ($LASTEXITCODE -ne 0) { throw "node --check ha fallado" }
  Write-Host "EJECUTAR.JS MIGRADO Y VALIDADO: PROJECT LANDING COMPOSER V2" -ForegroundColor Green
  Write-Host "Backup: $backup"
} catch {
  Copy-Item -LiteralPath $backup -Destination $Target -Force
  Write-Host "REPARACION FALLIDA. EJECUTAR.JS RESTAURADO." -ForegroundColor Red
  throw
}
