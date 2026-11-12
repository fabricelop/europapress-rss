# TTActualidad · relevo operativo entre chats · 12 noviembre 2026

> Documento persistente para continuar sin volver a preguntar al editor. Abrir este archivo desde GitHub en cualquier chat nuevo, comprobar datos vivos y actualizarlo con los resultados. No sustituye la memoria personal de ChatGPT ni contiene tokens.

## Encargo vigente del editor (12/11/2026, ~08:50 España)

1. Reparar imágenes que NO aparecen en la bandeja privada de TTActualidad aunque existen recibos.
2. Desatascar las órdenes de GitHub relacionadas con **Cobarde, Cantante(s) y Samantha Hudson** y **quitarlas de Listas**. El editor autoriza explícitamente esa retirada, no la publicación ni el borrado histórico.
3. APP: mostrar en cada tendencia que llega a Listas la **fecha/hora de su última aparición anterior** en Listas cuando no es la primera vez; corregir que **Quitar de Listas** deja la vista desplazada hacia abajo en vez de volver a cabecera/menú.
4. Seguir con autonomía dentro de cada turno; no pedir «sigue» después de cada comprobación. No prometer trabajo en segundo plano sin una automatización real.

## Arquitectura y seguridad

- Repo: `fabricelop/europapress-rss`, rama productiva `main`.
- Windows local: `C:\TTiTTulares`; puente remoto en rama `control/ttactualidad-support-bridge`, lee `support-bridge/next.json`, devuelve `support-bridge/results/<id>.json`. Herramientas builtin automáticas; PowerShell arbitrario pide aceptación WScript del editor. No eludir autorización, evitar órdenes simultáneas y revisar cada resultado.
- TTiTTulares y TTendencias, Cloudflare Workers; ChatGPT Web genera imágenes ImageGen, no crear sistemas de pago. **No duplicar galerías D1/R2, no cambiar la bandeja iPhone** como atajo, no regenerar imágenes que ya tienen recibo, no publicar/aceptar por cuenta del editor.
- Nombre de servicio privado: `https://ttactualidad.rainyraven22.chatgpt.site`; bandeja privada GET autenticado `/api/image-inbox/v1/images`, PNG `/api/image-inbox/v1/images/:id/original`, decisión POST `/api/image-inbox/v1/images/:id/decision`. El código interno del Site no está en este repo. La UI del editor necesita sesión autorizada; recibo de ingesta NO equivale a item visible hoy. Guía `site-patches/ttactualidad-fotos-review/ESTADOS-Y-APROBACION-20261111.md`. Otra iniciativa TT Fotos quedó definida **directo a fichas, sin almacenamiento paralelo**: `apps/tt-fotos/DIRECTO-A-FICHAS-SIN-ALMACEN.md`.

## Estado contrastado de imágenes

- PR #391 (`f0ff41e`): instalador de receptor de imágenes ya no exige función retirada `provesTop30AtImageCreation`.
- PR #392 (`7c13f23`): el instalador permite tarea antigua inexistente, pero evita dos receptores activos.
- PR #393 (`be8a7e5`): arregla variable reservada `$HOME` de PowerShell, cambiada por `$InboxHome`.
- Puente `ttb-inbox-homefix-20261112-0810`: `operation=installed_and_started`, tarea `TT Actualidad - Entrega IA gradual`; `ttb-inbox-receipts-after-install-20261112`: task `Ready`, `last_result=0`, 28 elegibles en ciclo (9 tendencias, 19 noticias), 16 chequeos/ciclo, muchos `RELAY_TAB_BUDGET` (limitador de pestañas Chrome) y otros `EXACT_CONVERSATION_UNAVAILABLE`.
- **13/13** encargos de imágenes recientes (12 TTendencias y 1 TTiTTulares) tienen recibos locales válidos, estado `pending`, comprobado con `ttb-inbox-13-recipient-check-20261112`. Ejemplo Josue: `2026-11-12T04:52:31.750Z`, `pending`, receipt id + rasterSHA256 válidos. Los recibos son la aceptación de ingesta histórica, NO prueba de que la bandeja UI los enumere.
- Conector `mcp__TTActualidad__verify_trend_image` (disponible por `functions.exec`) devuelve `pending_approval`, `published=false` para Broncano (`3b5034f473ba`), Paola (`69beea7215d2`), RTVE (`ba7633699cd1`), IRINI (`e386f83a422f`). La inspección de Top30 muestra `image_url:null` para ellos; eso es normal antes de aprobar.
- El usuario afirma de forma inequívoca que **no aparecen las imágenes en la bandeja**. No sostener que está reparado por tener recibos. Comprobar GET autenticado y la paginación/filtros/cliente del Site. Intento remoto de leer GET desde Windows (`ttb-site-inbox-feed-readonly-20261112`) terminó `declined` el 12/11 a las 07:26Z: respetar decisión. Si Site fuera de herramientas disponibles, solicitar entorno Work con sesión autorizada o acceso al código real; no inventar control del backend.
- Incidencia GitHub #394: `https://github.com/fabricelop/europapress-rss/issues/394` con detalles.

## Tres tendencias para retirar de Listas y liberar bloqueos

- Se han identificado por historia editorial `trends/editorial-runtime.json` (run `tr-20261111T191000-manual`):
  - Cobarde: `id=6519e0bfa504`, revisión 0.
  - Cantante (el editor dice «cantantes»): `id=52a0d9fe7897`, revisión 0.
  - Samantha Hudson: `id=e617da285349`, revisión 0.
- Los tres figuran como `applied:true` en el historial editorial de 11/11; eso NO garantiza que se hayan confirmado las órdenes GitHub de retirada. `trends/mobile-decisions.json` (actualizada 12/11) no mostraba registros para esos IDs al consultarla inicialmente. `trends/site-top30-current.json` el 12/11 08:46 contiene todavía Cobarde (`6519e0bfa504`) en ranking #19, pero pertenecer al radar Top30 no equivale a permanecer en Listas.
- **El editor autoriza quitarlos de Listas**. Antes de escribir, revisar el estado actual, la revisión/ID y el flujo autoritativo de decisiones GitHub (`ttactualidad_action_v1` / `trends/mobile-decisions.json` / aplicador). No hacer una supresión permanente del término ni borrar su historia por error. Verificar que ya no estén en Listas y que las órdenes asociadas queden resueltas sin duplicados. Es posible que el término «Cantante» difiera de «cantantes»: verificar fuente antes de actuar.

## Cambio APP solicitado

- Existe app iOS nativa en `ios/ttactualidad/TTActualidad`. `EditorialStore.swift` define `TrendItem`, `buildTrendListas` y snapshots. `EditorialView.swift` usa `ScrollView` + `LazyVStack`; `EditorialActionPanels.swift` tiene botón `Quitar de Listas`. También hay Site original (no necesariamente misma UI).
- Mostrar **última fecha/hora previa en Listas** únicamente cuando el registro histórico confirme que esa tendencia ya estuvo en Listas antes; no inventar fechas basándose en último `explained_at`, `entered_top30_at` o ranking. Guardar/consultar historial persistente de episodios de entrada/salida. Para tarjetas sin historial verificable, omitir etiqueta.
- Al quitar una ficha, gestionar desplazamiento en SwiftUI `ScrollViewReader` o id ancla, y controlar re-render/selección para devolver al menú/cabecera; no resetear scroll al tocar cualquier otra acción. Si el editor se refiere a UI del Site, necesitar acceso al frontend concreto; no afirmar que cambiar SwiftUI corrige la web.
- Verificar tests y CI `.github/workflows/ttactualidad-ios.yml`; publicar cambios solo con regresiones. La versión instalada en dispositivo puede requerir nueva compilación.

## Prioridades, instrucciones del editor
El usuario prefiere ejecución autónoma y resultados verificables, respuestas directas sin repetición de planes. Sus «Listas» son bandejas editoriales; retirar no es borrar del radar X ni desestimar publicación ya realizada. No aprobar imágenes, publicar X/Instagram, crear nuevos almacenes o tocar app original para salvar la incidencia. Mantener este documento actualizado con commits/PR, resultados y bloqueos reales.

## Avances posteriores verificados — 12/11/2026 (continuación de este chat)

**Tres retiradas completadas:** workflow temporal `.github/workflows/ttactualidad-remove-three-listas-20261112.yml` ejecutado con éxito (GitHub Actions run `43178874939`). En `pilot/ttactualidad-action-receipts.json` están los tres `status=applied`, `decision=deleted`, revisión 0:
- Cobarde `6519e0bfa504` — `tt-20261112-cobarde-r0`.
- Cantante `52a0d9fe7897` — `tt-20261112-cantante-r0` (el editor dijo «cantantes», esta es la identidad exacta del historial).
- Samantha Hudson `e617da285349` — `tt-20261112-samantha-hudson-r0`.
`trends/mobile-decisions.json` muestra los tres `deleted` y fuente `ttactualidad_direct`. Los tres fueron retirados de Listas sin eliminar el radar ni el historial. La APP anterior puede conservar órdenes pendientes locales por ausencia del recibo original.

**APP iOS:** PR #395 fusionada en `main`, commit `b7c1ecf3facf2a6b5b6b5e397566f4eb03c2fdc9`. Workflow iOS run `43179682059` pasó preflight, compilación Xcode y empaquetado IPA. El dashboard `TTDashboard.swift` usa `ScrollViewReader` y señal `removalScrollToken` para volver a cabecera/menú cuando el usuario confirma «Quitar de Listas» y el envío a GitHub se acepta. `EditorialStore.swift` calcula `previousListasAt` desde un episodio editorial anterior documentado de la misma tendencia, excluyendo simples cambios de ranking y actualizaciones del mismo episodio, y muestra «Anterior en Listas: fecha/hora» únicamente si existe. Requiere instalar la nueva compilación en iPhone, no se ha desplegado automáticamente en el dispositivo.

**Mejora extra de confirmaciones:** PR #396 `https://github.com/fabricelop/europapress-rss/pull/396` (estado por verificar): `GitHubEditor.swift` reconoce una decisión final por ID exacto, revisión y fecha posterior al envío consultando `trends/mobile-decisions.json` cuando se ha perdido el recibo de la orden original de la APP. No trata el 204 de GitHub como final y no falsifica recibos. Comprobar CI, fusionar solo si pasa y confirmar build IPA antes de declararla aplicada.

**Imágenes:** continúa SIN RESOLVER la visualización en la bandeja original. `mcp__TTActualidad__verify_trend_image` devolvió `pending_approval` para Broncano, Paola, RTVE e Irini, con `published=false`; 13/13 recibos locales `pending` con SHA válido probados previamente. El Site privado `ttactualidad.rainyraven22.chatgpt.site` y su GET autenticado `/api/image-inbox/v1/images` no son accesibles con los actuales conectores ni con el navegador público. No existe en el repositorio el backend real de ese Site. El intento de diagnosticar vía puente Windows se marcó `declined`, no forzar ni eludir consentimiento. Hay que comparar GET autenticado con los 13 recibos y corregir el frontend o backend real según responda; issue #394 con plan. No regenerar ni duplicar imágenes.
