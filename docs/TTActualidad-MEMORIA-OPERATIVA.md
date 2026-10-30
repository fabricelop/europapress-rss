# TTActualidad — memoria operativa integral y manual de rescate
**Revisión base: 29 de octubre de 2026.** Repositorio: **fabricelop/europapress-rss**. Este documento recoge arquitectura verificada contra código y decisiones de nuestras conversaciones. Es un **documento vivo**, no una garantía de salud en tiempo real.

> **Actualización prioritaria del usuario, 29/10/2026:** ya no se dan estrellas a los comentarios/remates y **sí se pueden pasar tendencias a noticias**. Verificado el botón iPhone «Enviar a TTiTTulares» y el handler `origin_trend` en main. Los JSON y párrafos de estrellas son restos históricos, no un paso actual que deba reactivarse. La prohibición antigua del puente no invalida la acción manual actual. Ver §§11–17 para evidencia, diferencias entre clientes y límites.

**Antes de una avería, abrir primero [LEER PRIMERO](TTActualidad-LEER-PRIMERO.md).** Guardar también [INCIDENTES Y DECISIONES](TTActualidad-INCIDENTES-Y-DECISIONES.md). Este manual se debe actualizar después de cada cambio en los componentes.

## 1. Principios obligatorios

1. **Identificar el sistema exacto** antes de tocar nada: app **iPhone nativa SwiftUI**, app **Windows nativa Qt**, backend GitHub/Windows/Cloudflare para editorial e imágenes, o la **web antigua**. La última NO es el código de las apps nativas.
2. **Main de GitHub es la autoridad de datos editoriales**; las instrucciones actuales del usuario prevalecen sobre contratos o memorias antiguos; la rama control es autoridad de triggers y algunos trabajos de imagen; los logs Windows son autoridad sobre lo que realmente ejecutó el PC. Un mensaje antiguo o una captura no sustituyen una relectura actual.
3. **Diferenciar estados:** una petición de radar, una cola PROCESSING/preparing, un disparador, un ACK picked_up/launched, un mensaje enviado a ChatGPT, un outbox, una escritura READY/explained, una imagen creada, una imagen capturada y un tuit publicado son **diez resultados diferentes**.
4. Siempre correlacionar **project + event_id/id + revision + request_id o command_id + fecha y zona Europe/Madrid**. Validar JIT, no sobrescribir decisiones de revisiones nuevas y no resucitar datos terminales.
5. Separar **texto** de **imagen**. La noticia debe llegar a READY y la tendencia a explained por texto validado; no bloquear por Imagen IA, foto de archivo ni Telegram.
6. Preservar FabCalendar, SeLoRecordamos, TTImages, URGENTE, RainETA, otros Workers y credenciales. Nada de reinicios de Chrome o procesos Node por intuición. No introducir Vercel ni gasto de pago.
7. El arreglo se verifica con un **elemento real por ID/revisión y relectura de JSON**. Una ejecución de Actions en verde, HTTP 204, estado Ready de Windows, ACK launched o contador 0/0 **no prueban** el cierre.

## 2. Arquitectura: cada eslabón y su propietario

~~~text
TTiTTulares: fuentes (medios) → radar_no_d1.py → telegram/events.json
→ auto_queue.py / treated_news.py (≥4 fuentes generales independientes, anti-repetidos)
→ telegram/editorial-processing.json + ttittulares/editorial-queue.json
→ trigger en rama control → listener dedicado Windows → Ejecutar.js → ChatGPT editorial
→ outbox (por archivo o comentario #164) → aplicador GitHub → prepared.json READY
→ Listas en iPhone/Windows → acción autenticada GitHub dispatch
→ decisions.json + action-receipts.json (+ publication-events.json si published)
                             ↘ JOB IA independiente → ImageBridge/CDP 9223
                               → ChatGPT Images → TTImageRelay/CDP 9234 → TTImages

TTendencias: fuentes públicas de tendencias → update_trends.py → recent.json (Top 30)
→ auto_queue_new.py (Top10 auto, 11–30 manual, reexplicaciones)
→ trends/requests.json + trends/editorial-queue.json
→ trigger en rama control → listener Windows → Ejecutar.js → ChatGPT editorial
→ outbox/reconciliador → trends/requests.json + trends/telegram-manual-explained.json
→ Listas / Explicadas iPhone/Windows → GitHub dispatch → mobile-decisions.json
                             ↘ JOB IA/foto independiente → ImageBridge → TTImageRelay
~~~

### 2.1 Código y servicios, NO confundir
| Pieza | Fuente actual / dónde está | Autoridad |
|---|---|---|
| App iPhone | ios/ttactualidad/TTActualidad/*.swift | interfaz y lectura de GitHub, NO fuente de decisiones persistidas |
| Versión iPhone 0.4.21 → 0.4.22 (29/10) | rama **feature/ttactualidad-ios-0.4.12-pistas**; ios/ttactualidad/project.yml | verificar rama de artefacto y versión instalada: main puede ir retrasado |
| Compilación iPhone | .github/workflows/ttactualidad-ios.yml | IPA sin firmar; PlumeImpactor firma app y extensión Live Activity |
| App Windows REAL | desktop/ttactualidad/TTActualidad_Moderno.pyw | Qt, GitHub directo; distribución preferida ZIP sin EXE |
| Compilación Windows | .github/workflows/ttactualidad-windows.yml | ZIP Sin-EXE o ejecutable; no confundir con Tkinter antiguo TTActualidad.py |
| Estado editorial | archivos JSON en **main** | READY / explained / deleted / published, recibos |
| Disparadores y jobs | ramas **control/**, no main | command_id, ACK, jobs de imagen |
| Envíos reales de editorial | C:\TTiTTulares\Ejecutar.js + windows/*DedicatedListener.ps1 | interacción ChatGPT/CDP 9223; script Ejecutar.js **local**, no asumir fuente GitHub |
| Imágenes, etapa 1 | windows/TTiTTularesImageBridge.js, TTendenciasImageBridge.js | lanza prompt en ChatGPT Images, modo vigente **launch_only** |
| Imágenes, etapa 2 | %LOCALAPPDATA%\TTImageRelay y Chrome **9234** | descarga/captura y envío **desde PC** a bot TTImages |
| Cloudflare tt-control | https://tt-control.fabricelop.workers.dev | API de control/ACK/jobs para listeners (no interfaz nativa) |
| Web anterior | docs/ttactualidad/index.html, pilot/ttactualidad-live y ttactualidad-decisions-pilot.fabricelop.workers.dev | **LEGADO**; actualizar Worker NO actualiza apps |
| Telegram editorial de noticias/tendencias | antiguos flujos send-*telegram | retirado como bandeja de control el 16–17/10; no reactivar |
| Instagram piloto | @ttactualidad, worker piloto y D1; antiguo botón Telegram | subsistema separado, manual y opt-in; no asumir que está integrado en los botones nativos |

### 2.2 Branches y autenticación
- GitHub main: todos los archivos editoriales/decisiones, salvo índices y jobs de **ramas control**.
- TTiTTulares: **control/ttittulares-run-trigger-v2** (cabeza del PR **#2**); archivos **ttittulares/run-now-trigger.json**, **ttittulares/run-ack.json**, **ttittulares/image-runs/**. Comprobar rama real del PR #2 antes de escribir.
- TTendencias: **control/ttendencias-run-trigger**; archivos **trends/run-now-trigger.json**, **trends/run-ack.json**, **trends/image-runs/**. Transporte de outbox por PR **#7**.
- iOS autentica con **GitHub App Device Flow**, guardado seguro en **Keychain**; no PAT incrustado. Windows usa **fine-grained PAT** limitado al repositorio con Contents R/W en **Windows Credential Manager/keyring**, independiente del iPhone. No compartir secretos.
- Acciones usuario: **POST GitHub /repos/fabricelop/europapress-rss/dispatches**, eventos **ttactualidad_action_v1** / **ttactualidad_manual_news_v1**, con **request_id**. HTTP 204 = recibido, NO aplicado.
- Los workers de la antigua UI web pueden seguir activos por compatibilidad, pero **no son la autoridad ni el cliente de las apps nativas**.

## 3. Proceso de TTiTTulares, paso a paso

### 3.1 Radar, fuentes y anti-duplicación
- Workflow actual **.github/workflows/radar-no-d1.yml**: cron declarado **05,15,25,35,45,55** (UTC), también dispatch y ciertos pushes. Un cron de GitHub Actions puede retrasarse.
- **telegram/radar_no_d1.py** capta fuentes generales, deportivas y de descubrimiento; trata fallbacks por fuente en paralelo, agrupa ocurrencias de un mismo evento, retiene títulos alternativos, URLs, marcas de primera/última aparición y familias independientes. Persistencia en **telegram/events.json**, **telegram/event-seeds.json** (historia de una fuente) y **telegram/processed-events.json**.
- **Número de fuentes a considerar:** **familias generales distintas** (source_families/source_count), no cuatro URLs del mismo grupo. La app puede mostrar **1/2 fuentes y variación** sin autorizar elaboración; salud de fuentes y contador van en status.json. Un radar sin fuentes NO debe traducirse a «no hubo noticias».
- Umbral automático: **mínimo 4 fuentes generales independientes** con evidencia del mismo hecho. Candidato WAITING/UPDATE_WAITING que no alcanza el consenso se poda tras **24 h desde first_seen**, según el código contrastado. Esto no caduca las fichas READY por ese plazo. Revalidar, no contar titulares copiados como corroboración.
- Selección de **ttittulares/auto_queue.py** consulta **ttittulares/treated_news.py** y decisiones: equivalencia semántica, URLs, identidad, alias, acciones/eventos ya tratados y actualidad. Evita que la misma historia entre desde otro medio. **Una novedad material distinta sí puede entrar**; no borrar tarjetas abiertas simplemente por tema parecido.
- Los filtros de ruido y patrones se hallan en **telegram/content_filters.py**, **ttittulares/auto_queue.py** y tests anti-repetición. No relajar el umbral para «llenar Listas». Noticias aportadas explícitamente por el usuario pueden forzar **investigación con menos de cuatro fuentes**, pero NO inventar hechos.
- **Registros derivados:** **ttittulares/status.json** para radar, revisión, creciendo y procesando; **telegram/editorial-processing.json** para estados detallados; **ttittulares/editorial-queue.json** espejo compacto que consume el editor. Asegurar consistencia de (event_id, revision).

### 3.2 Entrada a En elaboración
- Al ser elegible, auto_queue.py guarda **PROCESSING**, **selection_mode=AUTO_WEB**, selected_at, source_evidence, source_count y revision. Reescrituras/actualizaciones pueden ser **UPDATE_PROCESSING** o **rewrite_pending**.
- El flujo **＋ Noticia** desde app dispara **ttactualidad_manual_news_v1**, manejado por **ttactualidad-manual-news.yml** + **pilot/submit_ttactualidad_manual.py**: event_id manual, PROCESSING y recibo de solicitud. **Preparar** desde radar, propuestas explícitas y volver a elaborar conservan sus instrucciones/revisión.
- **Importante:** una cola con elementos PROCESSING **no significa** que ChatGPT ya esté redactando. Comprobar el disparador y la ejecución real.

### 3.3 Solicitud, escucha y envío ChatGPT
1. Tras commit en main, **ttittulares/request_pc_editorial.py --trigger** escribe **ttittulares/run-now-trigger.json** en el PR #2/branch control con command_id y ejecutor **pc_chat_ttittulares_dedicated**.
2. **windows/TTiTTularesDedicatedListener.ps1** lee control vía Cloudflare/RAW, intenta ACK picked_up, lanza **node C:\TTiTTulares\Ejecutar.js titulares --enviar**, y pasa el mensaje oficial **TTITTULARES_EDITORIAL_JOB_V2** mediante variable temporal **TT_CHAT_MESSAGE_B64**.
3. El script local debe confirmar el envío **real**; un launcher que termina con **ERROR: Target crashed** NO ha elaborado la noticia. Un ACK launched/ventana abierta tampoco demuestra cierre.
4. El editor lee **ttittulares/editorial-run-prompt.md** y en main **ttittulares/editorial-queue.json**, **ttittulares/status.json**, **telegram/editorial-processing.json**. Procesa TODOS los PROCESSING/rewrite_pending, en orden, con **barrera JIT (event_id,revision)** y antidualidad terminal. No llamar ImageGen en la misma pasada editorial.
5. Cada tuit listo: **hecho verificable**, salto en blanco, **2 hashtags específicos** (3 si caben), **UN remate 🌶️ en línea final**. **tweet.text completo ≤256 caracteres**; tweet.remate solo remate. El remate es satírico sobre el hecho documentado, no propaganda ni afirmación inventada. Víctimas: respeto.
6. Persistencia de nuevos resultados por **TTITTULARES_OUTBOX_V1** en comentario del **issue #164**. El contrato vigente prohíbe nuevos outboxes en PR #2 y escrituras editoriales directas en **ttittulares/editorial-outbox/**; PR #2 conserva control/telemetría. Los aplicadores de archivos son infraestructura existente, no una ruta libre alternativa. Procesos **ttittulares/ingest_pr_outbox_comment.py**, **ttittulares/apply_editorial_outbox.py**; workflows **ttittulares-outbox-comment-ingest.yml**, **apply-ttittulares-outbox.yml**. Valida revisión, longitud, texto y decisiones terminales antes de actualizar.
7. Cierre real: **ttittulares/prepared.json** contiene READY con factual_summary, tweet, remate, fecha, fuentes y revisión; **editorial-processing.json**, **editorial-queue.json**, **status.json** muestran transición. Comprobar **commit y relectura main** antes de contar salida. READY **NO** espera imagen IA, archivo ni Telegram.

### 3.4 Fin y decisiones
- **Listas** = entradas de prepared.json con texto, **sin** decisión terminal publicada/borrada/desestimada y sin revisión pendiente que las sustituya.
- **ttittulares/decisions.json** contiene tombstones **published / deleted / dismissed**. El mismo hecho no puede reaparecer por fuente tardía, caché o carrera de GitHub.
- **Reelaborar** implica nueva revisión y retirada de tarjeta anterior de Listas, conservando la identidad de la historia y sin duplicar imagen de la revisión anterior.
- El origen de cada noticia publicada/borrada y su comprobante se explica en el apartado 5.
- **No** eliminar candidatos de la UI por un detector de «tema parecido» si la selección del usuario era explícita y sigue activa. Diferenciar evitar duplicados en radar de eliminar fichas editoriales.

## 4. Proceso de TTendencias, paso a paso

### 4.1 Ranking y frescura
- Workflow **.github/workflows/ttendencias-refresh.yml** cron declarado **07,17,27,37,47,57** (UTC). **trends/update_trends.py** consulta múltiples fuentes públicas de términos en X, normaliza nombres, compara rankings por fuente, descarta datos sin fecha/antiguos si no hay corroboración; ante fallo conserva último radar con indicación de frescura.
- Principal: **trends/recent.json**: **top10, top30, items**, captured_at, fuentes, no-stale-source-count, ranking/movimiento/historial. **trends/checkpoint.json** y **ttendencias-refresh-watchdog.yml** respaldan comprobaciones. «Próximas tendencias» de puestos 11–50 son señales, no Top 10 confirmado.
- La selección Top10 debe atenderse aunque cambie la posición, sin saltarse solicitudes manuales ya registradas. Tras >48 h desde la última explicación puede abrirse un nuevo episodio con nuevo ID; el anterior conserva su terminal.

### 4.2 Elección de tendencias
- **trends/auto_queue_new.py**, **trends/requests.json**, **trends/editorial-queue.json**. **Top 10**: explicar automáticamente las no explicadas y reexplicar cuando caduca la explicación de **48 horas**. **11–30: únicamente Preparar/reexplicación explícita**; nunca seleccionar de oficio la siguiente 11–30.
- **Fuera del Top 30**: no entrar por ranking automático, pero una petición con pistas hecha por el usuario debe preservar ID, revisión y contexto aunque se mueva o salga del radar.
- Estados: **preparing**, **update** (nueva versión), **problematic** (bloqueo), **explained**, **grouped**, **inactive**, **deleted**, **published**. Una desaparición del Top 10 no equivale a borrar una petición manual.
- Agrupar solo tendencias que inequívocamente describen **un mismo hecho**: group_id, group_leader_id, trend_names y trend_context. Se usa explicación canónica, pero **cada request/estado** debe quedar reconciliado y no se borra ficha del usuario por deduplicación automática.
- Existe función manual **Tendencia → TTiTTulares**, confirmada por el usuario y por el código: botón iPhone **«Enviar a TTiTTulares»** → `GitHubEditor.addNews(originTrend:)` → dispatch **ttactualidad_manual_news_v1** → **pilot/submit_ttactualidad_manual.py**. Crea investigación PROCESSING con origen trazable; conserva la tendencia y no publica automáticamente. No pasa por el handler de decisiones ordinarias. Ver §12.5 para idempotencia, comprobación de origen y diferencias de Windows.

### 4.3 Elaboración y cierre explicado
1. Cuando la cola se ha escrito a main, **trends/request_pc_editorial.py --trigger** escribe **trends/run-now-trigger.json** en la rama control y ejecutor **pc_chat_ttendencias_dedicated**.
2. **windows/TTendenciasDedicatedListener.ps1** lee trigger/ACK, lanza **Ejecutar.js tendencias --enviar** con **TTENDENCIAS_EDITORIAL_JOB_V2**; leer primero **trends/editorial-run-prompt.md**.
3. El editor trata cada **preparing / update** vigente en orden con barrera JIT **(id,revision)**, investiga hecho verificable y no confunde el nombre de una tendencia con su causa. No generar ImageGen en la pasada editorial.
4. **explanation** copiable: **TT#N nombre literal es tendencia porque...**, línea de **2–3 hashtags específicos**, y remate único **🌶️** al final salvo casos sensibles que admiten cierre factual sin chiste. Menos de **280 caracteres ponderados según X**. **closer_text** contiene solo la línea 🌶️ (o vacío cuando corresponde). No duplicar cabecera TT#N en la app. Remates originales, un solo concepto, puntuación separada de texto.
5. Persistir **exactamente la misma explicación y revisión** en **trends/requests.json** y **trends/telegram-manual-explained.json**; en grupos, una ficha líder representa a todos los requests miembros explicados con su revisión propia; eliminar de **trends/editorial-queue.json** solo las revisiones realmente completadas. Aplicadores: **apply-ttendencias-chat-outbox.yml** (PR #7), **ttendencias-editorial-apply.yml** y reconciliador **ttendencias-editorial-reconcile.yml**, **trends/apply_direct_reconcile.py** cuando procede.
6. **Listas/Explicadas** requiere status **explained**, texto, explained_at coherente con petición, no tombstone ni revisión posterior preparando, no tarjeta grouped no líder, y cumplir filtro temporal de UI cuando aplica (48 h). **NO bloquear por IA/archivo/Telegram**.
7. **trends/mobile-decisions.json** conserva deleted/published; **trends/explained.json** es historial complementario y **trends/remate-ratings.json** guarda estrellas (no parte del tuit).


## 5. Listas, sincronización, botones y decisiones (iPhone + Windows)

### 5.1 Definición exacta de Listas
- **TTiTTulares Listas**: entradas de **ttittulares/prepared.json** con tweet/prepared_at, excluyendo IDs cerrados en **ttittulares/decisions.json** o apartados por rework de otra revisión. **ttittulares/status.json** es un resumen, no la única fuente de verdad.
- **TTendencias Listas**: últimas fichas **explained** de **trends/telegram-manual-explained.json**, coordinadas con **trends/requests.json**, fuera de **trends/editorial-queue.json** cuando su revisión está cerrada; excluidas tombstones **trends/mobile-decisions.json**, revisiones reabiertas y miembros grouped que no sean líderes. La app puede ocultar explicaciones de más de **48 h**.
- **En elaboración**: noticia PROCESSING/UPDATE_PROCESSING en cola detallada+compacta; tendencia preparing/update vigentes. «No comprobadas», «Creciendo» y «Top 30» son vistas de selección/radar, no archivos de texto ya elaborado.
- Una tarjeta puede desaparecer por **revisión**, **expiración visible**, **publicación**, **borrado**, **agrupación** o **fallo temporal de lectura**. No dar automáticamente por pérdida: investigar ID y estado.

### 5.2 Acciones editoriales desde la app nativa
1. **iPhone SwiftUI:** **EditorialStore.swift** construye la vista y reconcilia caché; **GitHubEditor.swift** usa GitHub App Device Flow y envía **repository_dispatch**; **EditorialActionPanels.swift** renderiza botones y construye **Copiar GAG**. La app maneja estado optimista y relectura; terminales guardados localmente impiden resucitar una tarjeta por un JSON de GitHub incompleto.
2. **Windows Qt:** **TTActualidad_Moderno.pyw** obtiene GitHub main, usa credencial propia almacenada por keyring, envía órdenes y muestra confirmación pendiente. Tiene ZIP **Sin-EXE** (Python/PySide6) y EXE opcional; no utilizar Tkinter antiguo para corregir sus botones.
3. **Comando:** evento **ttactualidad_action_v1** con project, event_id, revision, decision, request_id; **.github/workflows/ttactualidad-direct-actions.yml** invoca **pilot/apply-ttactualidad-action.py**. Añadir noticia: **ttactualidad_manual_news_v1** → **ttactualidad-manual-news.yml** → **pilot/submit_ttactualidad_manual.py**.
4. **Recibo:** **pilot/ttactualidad-action-receipts.json**, estados applied/already_applied, validados por **request_id**. Un **HTTP 204** indica que GitHub recibió el evento, NO que el workflow aplicó la decisión. Verificar commit y estado final; fallos o recibos ausentes se muestran como pendientes. **ttactualidad-auto-recover.yml** puede reintentar una vez un dispatch fallido; no convertir eso en éxito ficticio.
5. **Quitar de Listas** → **deleted** (sin contar publicación); **Desestimar** → **dismissed**; **Marcar publicada** → **published**. Los tombstones deben prevalecer ante cualquier réplica obsoleta; estado de la app no puede borrar una revisión más reciente. «Reelaborar» produce otra revisión y sale de Listas hasta tener un nuevo texto; «Aportar pistas» debe preservar información/manual override.
6. **Publicar en X ↗** abre el borrador en X, **no publica automáticamente**. Windows pide **Cerrar → Sí publicada / No retirar / Cancelar**. El primero da published cuando GitHub lo confirma; el segundo deleted; Cancelar no envía nada. Igual separación lógica de acciones en iPhone.
7. Los **contadores de publicaciones en las últimas 24 h** se calculan desde **pilot/ttactualidad-publication-events.json** (separados por proyecto, ventana móvil), no a partir de abrir el navegador, de una estimación de UI o del listado actual de Listas.
8. El usuario puede borrar un item de Listas pero el hecho seguir estando en el radar o Top30 por naturaleza del radar. Debe **estar cerrado editorialmente** y no reaparecer como ficha Lista. No borrar retroactivamente el radar solo para ocultar el término.
9. **Sincronización:** iPhone y Windows no comparten caché ni token; ambos deben consultar main fresco. Los cambios de UI optimistas **no** son autoridad. Un refresco parcial o caché desactualizada jamás debe deshacer tombstones. Verificar acciones por request_id, no solo por orden de llegada. Evitar sincronizaciones repetidas que lanzan decenas de descargas o bloquean el scroll.
10. **Live Activity iOS:** contadores de noticias/tendencias en Listas, pantalla bloqueada/Dynamic Island. Sin APNs, iOS puede dejar de actualizar la Live Activity cuando la aplicación está suspendida/cerrada; no interpretar el contador de bloqueo como estado vivo de main.
11. **Fotos archivo de la app:** galería únicamente para fotografías de archivo con URL/materialización validada en GitHub (ttittulares/archive-images, trends/archive-images), separada de imágenes IA. Si falta un archivo, mostrar no disponible, nunca sustituirlo silenciosamente por una ilustración generada.

### 5.3 Ficheros de aplicación y decisiones
| Archivo | Para qué sirve |
|---|---|
| ios/ttactualidad/TTActualidad/EditorialStore.swift | modelo de datos, secciones, filtros, contadores, caché/terminales |
| ios/ttactualidad/TTActualidad/GitHubEditor.swift | Device Flow GitHub, dispatch, recibos, solicitud editorial |
| ios/ttactualidad/TTActualidad/EditorialActionPanels.swift | acciones por noticia/tendencia, Copiar texto/GAG/archivo |
| ios/ttactualidad/TTActualidad/TTDashboard.swift | panel, Listas, Top30, Live Activity |
| desktop/ttactualidad/TTActualidad_Moderno.pyw | UI Qt nativa Windows, mismos datos y escrituras |
| pilot/apply-ttactualidad-action.py | actualizar decisiones con revisión JIT y recibo idempotente |
| pilot/submit_ttactualidad_manual.py | encolar noticia/solicitud manual en PROCESSING |
| pilot/ttactualidad-action-receipts.json | prueba definitiva de que un dispatch fue aplicado |
| pilot/ttactualidad-publication-events.json | ledger oficial de publicados declarados por el usuario |
| ttittulares/decisions.json | estado terminal noticias, anti-resurrección |
| trends/mobile-decisions.json | estado terminal tendencias, anti-resurrección |

## 6. Imágenes: política, trabajos y captura, deliberadamente separados

### 6.1 Tres pruebas distintas
1. **Texto completo:** READY en prepared.json o explained en los dos JSON de tendencias. No esperar imagen.
2. **Generación de ImageGen solicitada:** workflow visual crea **job image-runs** en la rama control por project+ID+revision+intento; listener obtiene control y bridge **launch_only** envía el prompt a ChatGPT Images en Chrome **9223**. ACK «launched» o «LAUNCH ONLY CONFIRMED» prueba el **envío del prompt**, **no** que exista fichero descargado ni imagen entregada.
3. **Captura y distribución real:** **TTImageRelay** con navegador **9234** independiente detecta/descarga el raster en PC y lo envía por **el propio PC** al canal/bot **TTImages**. No hay envío autorizado de imagen directa desde Actions a Telegram; **send-tt-ai-images.yml** es no-op por esta razón.

### 6.2 Propietarios de cada tramo
| Tramo | Código / estado |
|---|---|
| Encolar IA de noticia READY | .github/workflows/repair-ttittulares-listas.yml; ttittulares/prepared.json → image-runs/ en control |
| Encolar IA de tendencia explicada | .github/workflows/repair-ttendencias-explicadas.yml; trends/telegram-manual-explained.json → image-runs/ en control |
| Job IA y ACK | tt-control.fabricelop.workers.dev, ramas control, listeners Windows |
| Lanzar prompt IA | windows/TTiTTularesImageBridge.js / TTendenciasImageBridge.js y Chrome CDP 9223 |
| Pestaña fija por proyecto | C:\TTiTTulares\ttittulares-image-tab.json / ttendencias-image-tab.json |
| Locks e idempotencia local | C:\TTiTTulares\ttittulares-image-bridge.lock.json / ttendencias-image-bridge.lock.json |
| Captura/entrega PC | %LOCALAPPDATA%\TTImageRelay + Chrome 9234 + tareas TT Image Relay - Telegram v2 / Botones v2 |
| Diagnóstico TTImages | windows/Diagnosticar-TTImages-Relay.ps1, Diagnosticar-TTImages-Captura-Telegram.ps1 |
| Fotos de archivo | campos archive_image/fallback_image, carpetas archive-images; no bloquean READY |

- **Política editorial de imagen:** escena visual única, estilo detallado y expresivo, gag legible en 1–2 segundos, caricatura/sátira solo sobre hechos comprobados. **🌶️ jamás debe dibujarse** como guindilla/chile/pimiento. Si hay víctimas, tragedias o violencia sexual, ilustración rigurosa y sobria; no banalizar.
- **Copiar GAG nativo corregido 29/10:** **GAG_VISUAL_NATIVE_V2** dentro de **EditorialActionPanels.swift** (rama iOS actual) y **TTActualidad_Moderno.pyw** (Windows). **Una sola imagen horizontal 16:9, a sangre, SIN texto, subtítulo, hashtags, franja inferior, cartel, tarjeta, rótulo ni maquetación de noticia**. Texto y remate suministrados solo como contexto, nunca a dibujar. No arreglar este problema en la web antigua.
- Variación de estilos del trabajo automático definida por hash de ID/revisión/intento/command_id, entre cómic europeo, retro, pop art, cartoon 3D, stop-motion, novela gráfica y caricatura sofisticada. La prueba final es **visual**; un prompt correcto no impide por completo un fallo de ImageGen.
- **Idempotencia:** una imagen por proyecto+ID+revisión+intento. Estado de «generando», job iniciado, error transitorio y fallo de captura **no justifican lanzar varias imágenes simultáneas**. Ante una imagen capturada pero no entregada, reparar la entrega, no pedir otra generación.
- **Generación IA ≠ foto de archivo.** Derechos, procedencia y validez del raster deben verificarse. Imágenes de archivo opcionales: URL HTTPS, fuente fiable y estado de derechos; si no hay, dejar la ficha textual igualmente.
- **Comandos manuales ChatGPT Images** y **Copiar GAG** son controles deliberados, independientes del autoenriquecimiento. No restablecer los workflows heredados ttittulares-ai-image-apply.yml / ttendencias-ai-image-apply.yml, ni send-tt-ai-images.yml.

### 6.3 Problemas específicos de TTImages
- No confundir **Chrome 9223** (envío/bridge) con **9234** (captura/TTImageRelay). Un /json/version válido no garantiza que la pestaña corresponda al target correcto.
- Un fallo «Visor ya abierto al iniciar» se produce **en la descarga/captura**, no durante la elaboración del texto. Existe **windows/Recuperar-TTImages-Visor-Bloqueado.ps1**, pero no aplicarlo si hay una imagen actual o visor ocupado de manera legítima.
- Diferenciar **image-job pending → launch_only → respuesta de ImageGen → archivo Originales → envio Telegram TTImages → confirmación**. Registrar la primera transición que falta.
- Identificar command_id, target_id y revision. Comprobar la pestaña fija y que no haya otro proyecto generando. No modificar secretos de subida ni bot.

## 7. Calendarios, vigilancia y dependencias

| Tarea/workflow | Desencadenante declarado | Qué garantiza / no garantiza |
|---|---|---|
| radar-no-d1.yml | Cron :05/:15/:25/:35/:45/:55 UTC, dispatch/push | radar de noticias, no tuit final |
| redaccion-ttittulares.yml | Cron :15/:45 UTC | escribe **solicitud** editorial, no respuesta ChatGPT |
| ttendencias-refresh.yml | Cron :07/:17/:27/:37/:47/:57 UTC | Top30/encolado, no explicación |
| ttendencias-refresh-watchdog.yml | Cron :08/:38 UTC | vigila frescura del radar |
| ttendencias-editorial-reconcile.yml | Cron */15 UTC y push/dispatch | reconcilia requests/explicaciones escritas |
| apply-ttittulares-outbox.yml | Cron */10 y push/dispatch | aplica outbox de noticias si existe y es válido |
| ttittulares-outbox-comment-ingest.yml | Comentario TTITTULARES_OUTBOX_V1 | ingesta del texto desde #164/PR#2 |
| apply-ttendencias-chat-outbox.yml | Comentario TTENDENCIAS_CHAT_OUTBOX_V1 en PR #7 | ingesta tendencias |
| repair-ttittulares-listas.yml | Cron */5 y push | encola/repara imagen, no redacta |
| repair-ttendencias-explicadas.yml | Cron */5 y push | encola/repara imagen, puede conciliar cierre |
| tt-autorepair.yml | Cron */5 y push | detecta/despierta peticiones, **no redacta** |
| ttactualidad-direct-actions.yml | GitHub repository_dispatch | decisiones user por request_id |
| ttactualidad-manual-news.yml | GitHub repository_dispatch | encola noticia manual |
| ttactualidad-listas-alerts.yml | Push/cron | aviso best-effort de 0→positivo Listas |
| TTiTTulares Local / TTendencias Local | Windows Task Scheduler cada 15 min | lanzador, verificar **LastTaskResult**, no basta «Ready» |
| *DedicatedListener.ps1 + TT-LocalWatchdog | Procesos de fondo Windows | observan trigger, arrancan Ejecutor/bridge; comprobar logs y PID |
| TT-AutoUpdater.ps1 | mantenimiento local | descarga/valida scripts Python/PS/JS seleccionados; **Ejecutar.js local no se debe asumir sincronizado** |

**Zona horaria:** cron GitHub Actions es **UTC**, tareas Windows y UI muestran **Europe/Madrid**. No comparar minutos directamente sin conversión. Los schedules pueden retrasarse en GitHub, por lo que comprobar run_id, conclusion, commit y timestamp.

**Nota crucial:** la tarea de ChatGPT «Elaboración editorial TT» aparecía **desactivada** al revisarla el 29/10. Las tareas Windows pueden seguir enviando comandos por CDP; comprobar el consumidor efectivo de cada trigger. **Un trigger guardado en rama control no activa ChatGPT por sí mismo** si nadie lo consume.

## 8. Tabla de incidentes frecuentes y ruta exacta

| Problema | Qué leer primero | Qué comprobar | Confirmación |
|---|---|---|---|
| Radar de noticias vacío/viejo | telegram/events.json, status.json, radar-no-d1.yml | sources, fallbacks, independencia de familias, último run | nuevos eventos válidos y status fresco |
| 4 fuentes pero no PROCESSING | ttittulares/auto_queue.py, treated_news.py, events | elegibilidad, TTL, dedup, terminales, selección | ID+rev en editorial-processing y editorial-queue |
| Top30 inventado o viejo | trends/recent.json, update_trends.py | captured_at, diversidad, fuentes stale, consenso | top10/30 corroborados |
| Top10 sin preparar / 11–30 automático | trends/auto_queue_new.py, requests, queue | reglas Top10 auto, 11–30 SOLO manual y 48h | estado de cada id/rev correcto |
| Cola PROCESSING/preparing sin texto | run-now-trigger en rama CONTROL, listener, Ejecutar.js | trigger → picked_up → mensaje REAL en ChatGPT | outbox aplicado y READY/explained main |
| ACK launched pero no Listas | apply-outbox workflows, logs, campos revision | outbox, conflicto GitHub, tombstone, validación texto | relectura exacta JSON final |
| Imagen no aparece | image-runs rama control, ImageBridge, TTImageRelay | launch_only ≠ captura ≠ Telegram | imagen verificada tras entrega |
| Imagen con cartela | código nativo del botón Copiar GAG, ImageBridge prompt | no usar web anterior, separar texto de arte visual | ilustración a sangre sin texto |
| «Ya publicada» sin recuento | action-receipts, publication-events | usuario confirmó Sí, request_id applied, ventana 24h | ledger published único |
| Borrado reaparece | decisions/mobile-decisions, action-receipts, caché | terminal/ID/revisión, estado fresco main | no resurrección ni en iPhone ni PC |
| iPhone y Windows diferentes | version IPA/ZIP, main JSON, request_id | descarga/caché local y revisión | dos UIs coherentes tras refresco |
| Task Scheduler «Ready», última 1 | logs C:\TTiTTulares y procesos | ejecutor target crash, memoria, CDP 9223, ACK | nueva elaboración real terminada |
| Chrome «Target crashed» | TT-Editorial-Tab-Diagnose.js + InspectOnly memoria | tabs, target, carga, cmd, procesos; sin reinicios a ciegas | mensaje enviado y resultado persistido |
| Fotos archivo vs IA mezcladas | ArchivePhotoCatalog.swift, campos fallback | usar URL de archivo, no confundir IA | visor correcto para cada fuente |

## 9. Lo que se conoce de fallos reales y precauciones
- **Sincronización 29/10:** noticias y tendencias desaparecían/reaparecían entre móvil y Windows. Verificar **terminales + recibos + revisión + refresco**, no alternar entre dos backends.
- **«Copiar GAG» 29/10:** se corrigió por error la **web antigua** y se llegó a desplegar su Worker. No resolvía las apps. Arreglo real: botones **nativos** en iOS **0.4.22** (rama feature) y Windows Qt, binarios compilados. **No afirmar que están instalados si solo existen artifacts**.
- **Procesamiento 29/10:** dos Windows Local «Ready» pero **LastResult=1**; listeners vivos, CDP 9223 accesible, **Ejecutar.js** devolvía **ERROR: Target crashed**. TTiTTulares reintentaba cada ~15s; backoff añadido de **10 minutos**. TTendencias ya tenía backoff 10min.
- **Memoria y Chrome:** Windows informó episodios **Memory Exhaustion Event 2004** a las 19:40–19:57 y consumo global comprometido luego mucho menor; NO se demostró agotamiento en el momento del fallo. Un script PowerShell 5.1 contaba erróneamente pestañas de CDP como 0 mientras Node veía 4; se corrigió enumeración. Nunca usar un contador aislado para cerrar Chrome.
- **Recuperación Chrome9223:** recuperador **Recover-TT-Chrome9223-Controlled.ps1** con perfil dedicado, respaldo, bloqueo por runner/imagen/respuesta/draft/estado incierto. Una ejecución real a las 21:52 se **ABORTÓ** antes de tocar nada al detectar **1 proceso activo**. Eso es salvaguarda correcta, no demuestra un proceso colgado.
- **Texto e imágenes separadas:** en múltiples ocasiones parecía que «GitHub está atascado» por imágenes; no bloquear READY/explained mientras el pipeline IA trabaja. Una imagen de ChatGPT puede existir aunque su entrega TTImages esté pendiente.
- **Seguridad de corrección:** un script nuevo no es válido por estar en GitHub; ejecutar CI de sintaxis/test (especialmente Windows PS5.1) antes de pasar comando. No cambiar automatizaciones ajenas ni ImageGen mientras se corrige editorial.
- **Estado de colas:** en una observación del 29/10 a las ~21:46 ambas colas llegaron a 0; más tarde una revisión detectó nuevo PROCESSING. Por eso **0/0 es un instante**, no una prueba de continuidad.

## 10. Cómo intervenir sin reconstruir una hora

1. Leer [ficha de emergencia](TTActualidad-LEER-PRIMERO.md) y este manual; comprobar si el incidente es **radar / selección / editorial / outbox / decisiones / imagen / UI**.
2. Leer el **código vigente**, no solo README: rama iOS adecuada, main, control branches, workflows activos, contratos de elaboración. Obtener un ID/revisión que falle y su ruta completa.
3. Obtener señales **sin cambios**: GitHub main (cola, terminal, receipt), rama control (trigger y ACK), logs local Windows y CDP, job imagen y TTImageRelay si corresponde. No exponer secretos/URL de tokens.
4. Localizar **la primera transición ausente** en la cadena. Proponer/aplicar cambio mínimo y reversible. No vaciar ni editar masivamente datos para esconder el problema.
5. Validar sintaxis, tests y GitHub Actions antes de instalar scripts/ejecutables o tocar Chrome. Confirmar actualización local efectiva del listener o app.
6. Reprocesar **solo** los trabajos pertinentes si siguen elegibles, sin duplicar ejecuciones/imágenes; verificar tombstones y revisiones.
7. **Releer main** después, verificar ID/revisión y destino; probar en ambas apps. Si es imagen, certificar por separado envío prompt, raster, fichero en PC y entrega TTImages.
8. Actualizar esta memoria y [el historial de incidentes](TTActualidad-INCIDENTES-Y-DECISIONES.md) con fecha, síntoma, causa demostrada, componente, archivos/commit, prueba y resultado final.

### 10.1 Qué NO se puede deducir solo de esta memoria
La versión **instalada** en iPhone/Windows; si la tarea ChatGPT se activó; el estado actual de todas las colas; si la última imagen de Images llegó a TTImages; si hay procesos de imagen ocupados; y publicaciones en X fuera del propio ledger de TTActualidad. **Comprobar cada vez**.

### 10.2 Fuentes principales a consultar al actualizar la memoria
- **Contratos editoriales actuales:** ttittulares/editorial-run-prompt.md; trends/editorial-run-prompt.md; trends/editorial-style.md.
- **Radars y selección:** telegram/radar_no_d1.py; ttittulares/auto_queue.py; ttittulares/treated_news.py; trends/update_trends.py; trends/auto_queue_new.py.
- **Aplicación y escrituras:** ios/ttactualidad/TTActualidad/EditorialStore.swift; GitHubEditor.swift; EditorialActionPanels.swift; desktop/ttactualidad/TTActualidad_Moderno.pyw; pilot/apply-ttactualidad-action.py; pilot/submit_ttactualidad_manual.py.
- **Motores/aplicadores:** ttittulares/apply_editorial_outbox.py; trends/apply_editorial_outbox.py; trends/apply_direct_reconcile.py; shared/ttendencias_queue_reconcile.py; shared/tt_autoheal.py; shared/tt_editorial_run_guard.py.
- **Windows y visuales:** windows/*DedicatedListener.ps1; windows/*ImageBridge.js; windows/TT-LocalWatchdog.ps1; windows/TT-AutoUpdater.ps1; windows/Diagnose-TT-Editorial-Local.ps1; windows/TT-Editorial-Tab-Diagnose.js; windows/Diagnosticar-TTImages-Relay.ps1.
- **Workflows:** radar-no-d1, redaccion-ttittulares, ttendencias-refresh, apply-ttittulares-outbox, ttittulares-outbox-comment-ingest, apply-ttendencias-chat-outbox, ttendencias-editorial-reconcile, tt-autorepair, repair-ttittulares-listas, repair-ttendencias-explicadas, ttactualidad-direct-actions, ttactualidad-ios, ttactualidad-windows.
- **No usar como norma vigente sin comprobar:** README TTiTTulares antiguo (dice sin IA), partes de editorial-config.json antiguas (11–30 «siguiente»), workflows Telegram desactivados, web antigua y copias iOS antiguas en main.

## 11. Revisión contrastada del 29/10/2026: alcance y pruebas

**Corte de código principal:** commit [`0fb2cfbcbd1d1aabb820413b01b6dc451c7aaf20`](https://github.com/fabricelop/europapress-rss/commit/0fb2cfbcbd1d1aabb820413b01b6dc451c7aaf20), 29/10/2026 22:32:26 Madrid. **Fuente iOS contrastada:** `feature/ttactualidad-ios-0.4.12-pistas`, commit `dedcaabf1134be45b16efe482cf67ceec67e4998`, versión **0.4.22, build 28** declarada en `project.yml`. Esto no certifica su instalación; conservar 0.4.21 como última base indicada por el usuario hasta confirmación posterior.

Se han leído las tres memorias previas, código de radar, selección, identidad, contratos editoriales completos, aplicadores, acciones, normalización de Windows, tres componentes SwiftUI de la rama indicada, listeners, puentes, reparadores, vigilancia y Tremending. También se han recuperado conversaciones mediante búsqueda y leído íntegramente `CONTINUIDAD-TTActualidad-20261029.txt` y `ESTADO_MAESTRO_2026-10-16.md`. La recuperación de conversaciones es selectiva: **no es una exportación exhaustiva de todos los chats del proyecto**. No se ha accedido al Windows físico ni a las apps instaladas ni se han ejecutado reparaciones durante esta investigación.

Los archivos principales se contrastaron por su blob SHA entre dos lecturas del árbol; los cambios intermedios observados afectaban a feeds generales, no a los componentes de esta revisión. Los datos posteriores al corte deben releerse antes de intervenir. El estado de una cola no se convierte en garantía de funcionamiento continuado.

### 11.1 Qué se corrigió respecto a la memoria inicial

| Punto | Regla contrastada que debe usarse |
|---|---|
| Transporte TTiTTulares | Nuevos `TTITTULARES_OUTBOX_V1` al **issue #164**. El contrato prohíbe nuevos outboxes en PR #2 y escrituras directas en `ttittulares/editorial-outbox/**`. El aplicador sigue existiendo; eso no autoriza usar cualquier entrada histórica. |
| TTendencias → TTiTTulares | **Sí existe envío manual autorizado**: botón nativo iPhone, dispatch de noticia manual, validación `origin_trend` y PROCESSING. El párrafo de prohibición del contrato está desactualizado respecto a este flujo. |
| Estrellas | **Ya no se dan estrellas**, confirmado por el usuario y sin controles de puntuación en las 16 fuentes Swift revisadas ni en la UI Qt. Los historiales y obligaciones textuales antiguas se documentan como restos, sin reactivarlos. |
| Borrado de tendencias | Cierra el episodio/revisión. Tras más de 48 h puede abrirse un **episodio distinto con nuevo ID**; no es resucitar la ficha borrada. |
| Ventanas temporales | Radar 24 h, explicaciones visibles 48 h y encolado automático IA 24 h son ventanas diferentes. |
| Windows moderno | La UI es Qt en `.pyw`, pero **importa funciones de `TTActualidad.py`**: sus modelos/filtros comunes también intervienen. No confundir ese uso con abrir su antigua UI Tkinter. |
| Fotos de archivo | Un `archive_image_status=ready` puede coexistir con derechos `unverified`; disponibilidad técnica no significa autorización de reutilización. |

### 11.2 Jerarquía de evidencias

1. **Decisión vigente del usuario**, aunque un contrato o memoria del repositorio siga diciendo lo contrario.
2. Evidencia de las acciones disponibles y del handler que las consume. Las reglas del contrato se contrastan con esa decisión y ese código antes de llamarlas vigentes.
3. Código ejecutable de la rama/versión correcta y workflows productivos.
4. Estado persistido por ID/revisión, commit, recibo y logs de la ejecución concreta.
5. Memorias, README y conversaciones anteriores como contexto fechado.

**No resolver contradicciones escogiendo el párrafo más cómodo.** Los contratos conservan secciones antiguas de Telegram, Principal/A/B/C e imágenes; sus encabezados de prioridad las invalidan donde chocan con el flujo actual. Documentar el conflicto y verificar el handler real. Las cadenas `mode:web` y carpetas `telegram/` son nombres históricos y no implican que la interfaz actual sea la web antigua ni que se envíen tarjetas editoriales.

## 12. Catálogo de captación, selección y memoria de repetidos

### 12.1 Radar de noticias: qué entra y qué cuenta

`telegram/radar_no_d1.py` declara **19 medios generales**, **5 deportivos** y **3 entradas de descubrimiento**. Generales: Europa Press, EL PAÍS, La Vanguardia, Cadena SER, RTVE, El HuffPost, 20minutos, ABC, COPE, EFE, Servimedia, elDiario.es, Público, El Mundo, Antena 3 Noticias, laSexta Noticias, Onda Cero, Telecinco Noticias y Noticias Cuatro. Deportivos: AS, MARCA, Mundo Deportivo, SPORT y EFE Deportes. Descubrimiento: Reuters Radar, AP Radar y Público · Tremending.

El código trata Antena 3/laSexta/Onda Cero como **una** familia Atresmedia y Telecinco/Cuatro como **una** familia Mediaset. Por tanto hay **16 familias generales según este mapa**, no 19 fuentes independientes a efectos del umbral. Los deportivos y el descubrimiento ayudan a detectar/agrupar, pero **no cuentan para las cuatro familias generales**. Este mapa es la implementación comprobada, no una auditoría completa de propiedad o independencia editorial de todos los medios.

Captura mediante RSS/HTML y fallbacks por medio, con recuperación Google News por dominio y ventana retrospectiva. Guarda cada aparición, URL, título, tipo de fuente, familia y fechas. Consolida titulares del mismo hecho y depura apariciones discordantes antes de declarar elegible. Un contador cuatro tras agrupar no basta si la evidencia no corresponde al mismo hecho.

`WAITING` / `UPDATE_WAITING` → consenso de ≥4 familias → `ELIGIBLE` / `ELIGIBLE_UPDATE`. Una revalidación puede devolver a WAITING un evento que pierda evidencia al depurar o consolidar. En modo actual `web`, este paso no envía aviso editorial Telegram. El mínimo de salud declarado es **14 medios generales**; no confundirlo con el umbral cuatro ni con el total configurado.

### 12.2 Cuatro barreras contra repetir noticias

| Barrera | Mecanismo | Dónde investigar un rechazo |
|---|---|---|
| Captación | URLs, títulos alternativos y agrupación de apariciones del mismo suceso | `radar_no_d1.py`, `events.json`, `event-seeds.json` |
| Identidad de hechos tratados | URL normalizada sin query, alias léxicos, tokens, similitud y actos concretos; historial de tratados/entregas | `treated_news.py`, `treated-stories.json`, decisiones |
| Selección automática | Excluye ID terminal, ya preparado, cola existente, historia similar activa/histórica, desactualizada, contenido filtrado o sorteo rutinario | `auto_queue.py`; logs `AUTO_QUEUE_*_SKIPPED` |
| Persistencia editorial | Revisión vigente JIT, decisión terminal y duplicado de un hecho ya cerrado | contrato, `apply_editorial_outbox.py`, recibo y cola |

El detector de hechos tratados diferencia algunas acciones posteriores: remitir a la Justicia frente a una mera información previa; abrir/incoar frente a archivar/rechazar. **No es un modelo semántico infalible**: usa heurísticas, y `auto_queue.py` contiene además su propio comparador `same_story`. Ante una noticia nueva bloqueada, identificar la referencia concreta y su acto material, no cambiar umbrales a ciegas.

La selección automática exige actualidad de **24 horas**, normalmente desde `first_seen` —ver otra vez la misma pieza no reinicia su edad—. Una actualización material validada puede usar `last_seen`. Para `ELIGIBLE_UPDATE`, deben existir flags/contexto explícitos de cambio material. El mismo ID terminal se conserva cerrado; una novedad real debe mantener su identidad editorial adecuada.

El historial de referencia en `treated_news.eligible_reference()` usa una ventana de **180 días** para sus fechas de entrega/tratamiento/procesamiento; si no hay fecha válida, la referencia sigue siendo elegible. Esto **no es una orden de borrar decisiones a los 180 días**. El mapa terminal por ID se consulta por separado. Borrar una noticia no significa que nunca más pueda publicarse otro acontecimiento sobre la misma persona.

Si durante la pasada se demuestra un duplicado, cerrar por outbox `status:duplicate`, ID original, motivo y `no_material_update:true` cuando corresponda; el aplicador comprueba el original y registra el cierre. Un resumen diciendo «duplicada» sin transición persistida deja trabajo pendiente. No eliminar automáticamente una tarjeta ya materializada por mera similitud temática.

### 12.3 Radar de tendencias: origen y fiabilidad

`trends/update_trends.py` declara **13 agregadores públicos**: trends24, getdaytrends, tweets24, superx, twtdata, snaplytics, whatstrends, cyberkendra, xtrendsiamrohit, trendswe, xtrendssaroj, playersells y fowtools. Son rankings agregados públicos; no asumir que se está leyendo el ranking interno oficial de X por API.

Limpia términos, normaliza para comparar mayúsculas, acentos y `#` inicial conservando el nombre visible. Comprueba fecha/antigüedad de cada fuente, coincidencia entre listas y consenso; una fuente sin fecha necesita corroboración. Ante fallos no debe inventar un Top30 fresco a partir de la última descarga antigua. Revisar `captured_at`, método, fuentes válidas, antigüedad y checkpoint; una descarga reciente puede contener ranking viejo.

Top10 → selección automática. Puestos 11–30 → petición manual explícita. Las señales «Próximas tendencias» fuera del Top30 combinan movimiento/corroboración social y señales de noticias; no equivalen a una explicación comprobada. El usuario sí puede ordenar investigar una tendencia como noticia mediante el envío manual descrito a continuación. Una petición que entró legítimamente desde Top10 sigue pendiente aunque luego cambie de puesto; el código conserva `auto_queue_scope:top10`.

La caducidad de **48 h** se calcula desde la última explicación fechada, no desde el último borrado. Si falta una fecha válida, el selector no reabre masivamente. Un nuevo episodio puede conservar el nombre y obtener un ID nuevo, con `originated_from_prior_id`; la ficha histórica y sus decisiones no se reactivan.

### 12.4 Tremending: circuito propio de lectura

**No confundir con el radar de tendencias ni con noticias autoelaboradas.** `tremending-collect.yml` corre en minutos **07,22,37,52 UTC**, además de dispatch/trigger. `ttittulares/tremending/update_tremending.py` revisa las primeras ocho páginas de Público/Tremending, desde la frontera **30/09/2026 00:00 Madrid** declarada, extrae artículos y tuits incrustados, deduplica URL canónica y persiste `ttittulares/tremending/items.json`.

La app muestra una bandeja de lectura. **No selecciona ni captura automáticamente tuits ni los envía a ninguno de los dos proyectos.** `tremending-capture.yml` es un no-op manual. Al borrar, el handler retira físicamente la entrada de `items.json` y conserva su URL en `scan.seen_urls`, además del registro pertinente de decisión; el recolector no la reintroduce. Si faltan embeds, conserva la pieza para reintentar su extracción.

### 12.5 Pasar una tendencia a noticia: recorrido real comprobado

**Sí está permitido y existe.** En la fuente iPhone contrastada `EditorialActionPanels.swift` muestra **«Enviar a TTiTTulares»** y confirma **«¿Investigar esta tendencia como noticia?» → «Enviar a En elaboración»**. `sendTrendToNews()` calcula un UUID estable desde `ttactualidad-trend-news:<ID>:r<revision>`: repetir el toque/reintento de esa revisión reutiliza la identidad. Crea operación local «De tendencia a noticia», con ID `manual-<UUID>`, y consulta Órdenes pendientes. Una revisión posterior puede generar una solicitud diferente.

`GitHubEditor.addNews()` envía `ttactualidad_manual_news_v1` con proyecto TTiTTulares, título «Investigar noticia: …», instrucciones de contraste y `origin_trend:{id,revision,name}`. **No copia automáticamente la explicación como noticia verificada**: la incluye como contexto preliminar. La tendencia sigue en TTendencias y no se publica ni se borra por esta acción.

En main, `.github/workflows/ttactualidad-manual-news.yml` ejecuta `pilot/submit_ttactualidad_manual.py`. Verifica origen exacto en requests, catálogo histórico explicado/publicado o Top30 real; rechaza ID inventado, nombre distinto y revisión obsoleta. Puede aceptar una tendencia histórica auténtica aunque haya salido del ranking. Guarda `origin_project`, `origin_trend_id`, `origin_trend_revision`, `origin_trend_name` y crea **PROCESSING r1** en **las dos colas de noticias**. Es petición manual con cero fuentes iniciales permitidas para investigar, no permiso para inventar hechos.

El handler evita repetir el mismo event_id y detecta algunos duplicados de URL/título; escribe recibo `applied`, `already_applied` o `rejected`, con `existing_event_id` si hay otra noticia. El workflow persiste primero y después solicita al editor de TTiTTulares; si rechaza, no dispara una elaboración. Correlacionar recibo y cola: `applied` prueba la entrada, **no** el cierre READY posterior.

**Prueba ejecutada durante esta revisión:** ocho tests sintéticos existentes en `pilot/test_ttactualidad_trend_to_news.py`, todos correctos. Cubren ambas colas, conservación de la tendencia, reintento idempotente, origen histórico, rechazos y recibos. No se ha creado una noticia real ni probado el toque en el iPhone físico durante esta investigación.

**Diferencia de clientes:** en el `.pyw` Qt de main revisado no aparece ese botón específico ni el payload `origin_trend`; sí existe «+ Noticia» genérico. No declarar paridad completa por compartir backend. La capacidad de pasar tendencias está comprobada en iPhone y backend; localizar versión/implementación Windows si se investiga su ausencia, sin negar la función global ni añadirla por esta tarea documental.

## 13. Elaboración, progreso y remate único

### 13.1 Dos maneras de iniciar el mismo trabajo editorial

- **Automática/solicitada desde app:** radar/acción → cola persistida → trigger control → listener Windows → `Ejecutar.js` → mensaje real a ChatGPT → investigación → cierre persistido.
- **Orden explícita «Ejecuta TTiTTulares/TTendencias» en chat:** el editor debe hacer la pasada **en esa conversación**. No basta con cambiar el trigger y decir que está ejecutado; delegar solo sirve si existe consumidor activo y confirmación RUNNING. La ausencia de Windows no impide necesariamente una pasada directa con acceso autorizado a GitHub y fuentes.

Investigar el motivo **actual** con fuentes contrastables, conservar fuentes/atribuciones, aplicar JIT antes de cada entrada y antes de persistir. Las pistas del usuario (`user_pistas`, `rewrite_instruction`) orientan la búsqueda pero no prueban hechos. Si no se verifican, conservar pistas/historial y motivo concreto en revisión/problematic; no rellenar con una causa inventada.

### 13.2 Estrellas retiradas; restos históricos en el repositorio

**El usuario confirma el 29/10 que hace tiempo que ya no da estrellas a los comentarios/remates.** Se ha buscado su UI en las **16 fuentes Swift** de la rama iPhone contrastada y en la UI Qt revisada: no se han encontrado controles de estrellas/valoración. No pedir puntuaciones, reinstalarlas ni incluirlas como eslabón operativo actual.

Siguen existiendo `ttittulares/remate-ratings.json`, `trends/remate-ratings.json` y párrafos de ambos contratos que exigen congelar ratings, cinco candidatos internos y telemetría de puntuación. **Son una discrepancia documental real**, no prueba de uso actual por el usuario ni de que el sistema deba esperar estrellas nuevas. Los históricos no se borran. No se ha demostrado un mecanismo sustituto de valoraciones; no inventar likes, aprendizaje automático ni otro control equivalente.

El resultado actual sigue siendo un texto factual con un único remate pertinente cuando proceda, respetando longitud, veracidad, sensibilidad y las preferencias editoriales explícitas. Las instrucciones antiguas de puntuación deben revisarse aparte si se quiere alinear el contrato de ejecución; esta investigación solo corrige la memoria y no modifica prompts productivos ni sistemas de valoración.

### 13.3 RUNTRACE no sustituye el texto persistido

`TTITTULARES_RUNTRACE_V1` y `TTENDENCIAS_RUNTRACE_V1` muestran fases reales: verificar estado, investigar, redactar, `remate_selection`, persistir, verificar y cerrar. Actualizar el comentario canónico existente, sin crear una traza por cada refresco ni fingir progreso mediante temporizadores. En TTendencias el runtime durable también es `trends/editorial-runtime.json.last_run`.

Los campos históricos `ratings_snapshot` y `remate_selections` aún aparecen en contratos/runtime; no prueban que la app siga pidiendo estrellas. No fingir una selección/puntuación ni inventar datos para rellenarlos. Un DONE global sin cierre por ID/revisión no vacía la cola. El PR #2 conserva control/telemetría, pero el texto nuevo de noticias va por #164.

### 13.4 Cierre agrupado de tendencias

Solo agrupar el **mismo episodio comprobado**, conservando cada `(id,revision)`, aunque las revisiones difieran. El líder es la etiqueta de la emisión o el mejor rank, con desempate por antigüedad. Se guarda una ficha de grupo en `telegram-manual-explained.json`; todos sus miembros quedan `explained` en `requests.json` con explicación/grupo coherentes. Solo el líder aparece en Listas; los demás deben salir de En elaboración y figurar como explicados/cubiertos.

`batch_id`, captura simultánea o nombres de un mismo programa no prueban pertenencia al mismo episodio. No borrar miembros ni crear nueve fichas para un grupo ya demostrado. Para reconciliar, validar IDs/revisiones y vínculo al líder, no solo nombres. El caso de grupo es la excepción a exigir una ficha independiente en el catálogo por cada solicitud.

## 14. Cuándo desaparece cada cosa y qué debe conservarse

| Objeto/acción | Transición o retirada | Conservación y prueba |
|---|---|---|
| Noticia WAITING/UPDATE_WAITING sin consenso | Poda tras **24 h desde first_seen** | No equivale a borrar un READY ni una decisión del usuario. |
| Memoria ligera de una fuente | `event-seeds.json`, 24 h; límite **40.000** | Permite recuperar apariciones que salen del cap operativo; deja de necesitar seed al sumar otra familia. |
| Registro de procesadas del radar | `processed-events.json`, últimas **2.000** entradas | Cap operativo; no sustituye a decisiones/treated-stories. |
| Noticia publicable | PROCESSING → READY; aparece en prepared/Listas | Cierre de texto independiente de imágenes. |
| Noticia no verificable | PROBLEMATIC/revisión con motivo | No tratar como borrada ni como preparada; Check/manual puede abrir investigación válida. |
| Quitar noticia de Listas | `deleted`; retirada de prepared y decisión | Conservar recibo/ID/revisión, no sumar publicación. |
| Desestimar noticia en elaboración | `dismissed`/DISMISSED | Decisión terminal, no simple ocultación local. |
| Marcar publicada | `published` y ledger de publicación | Cuenta móvil de 24 h; no asumir publicación real en X solo por abrirlo. |
| Reelaborar/Reexplicar | Revisión nueva; tarjeta anterior deja de ser la vigente | Mantener identidad, historial, pistas; no heredar puntuaciones o imagen sin verificar. |
| Tendencia explicada que deja el Top | Cambio de ranking independiente | No borrar petición manual ni su explicación por caer de puesto. |
| Tendencia en Listas con >48 h | Filtro temporal de UI la excluye | El histórico no se destruye; selector puede abrir nuevo episodio si corresponde. |
| Borrar/publicar tendencia | Terminal para episodio/revisión, sincronización de requests/catálogo/decisión | Un JSON explicado viejo no debe revivirla; revisión nueva no se borra desde una ficha antigua. |
| Miembro de grupo explicado | Sale de elaboración; cubierto por ficha líder | Preservar request explicado y vínculo al grupo. |
| Borrar Tremending | Retirada física de items + URL en seen_urls | Evita que vuelva a entrar desde Público. |
| Job IA que sale del índice | LAUNCHED, cancelado o ya no elegible | Consultar `jobs/<id>.json`: índice vacío **no prueba ausencia de generación** ni autoriza repetirla. |
| Originales TTImages | Política histórica confirmada: limpieza cada hora de originales >**12 h**, incluso no enviados | Verificar que la tarea siga vigente; no borrar huellas, exclusiones, historiales ni decisiones. |
| Limpieza técnica Telegram | Solo IDs técnicos conocidos, recibidos hace **2 min–47 h** | `shared/tt_technical_cleanup.py`; nunca tarjetas editoriales, fijados o mensajes del usuario. |

**Tres acciones distintas:** copiar texto/foto no publica; abrir el borrador X no publica; la confirmación explícita Sí publicada registra publicación declarada. El ledger de TTActualidad no es por sí solo una auditoría de todo lo publicado fuera de la app en X.

## 15. Imágenes y archivo: diagnóstico sin duplicarlas

### 15.1 Ventana, estado y recibo

Los reparadores actuales encolan IA para textos vigentes sin imagen válida, con fecha de entrada/explicación de **hasta 24 h**, respetando terminales y trabajos anteriores. En noticias el paso comprueba texto **y remate no vacío**; por tanto un READY sensible sin remate puede quedar fuera de esa ruta automática aunque la política general permita imagen sobria. **Registrar esta diferencia de implementación antes de atribuir el fallo a ChatGPT.** No cambiar el texto ni inventar un remate para forzar la imagen.

`shared/tt_image_idempotency.py` gobierna permisos de reencolado. `REQUESTED/RUNNING/GENERATING/PERSISTING/PICKED_UP/UNCERTAIN` y `DONE/LAUNCHED/READY/COMPLETED`, o cualquier marca `pc_submitted_at/pc_launched_at`, impiden repetir el mismo trabajo. Un ERROR tras recogida por PC puede coexistir con generación real: **no es prueba de que no se envió**. Un token de reintento manual no salta un job activo/lanzado.

Solo se permiten reintentos automáticos acotados cuando se demuestra que falló **antes del envío** —por ejemplo, el compositor no utilizable expresamente reconocido—, o una identidad editorial nueva. El límite habitual de reintentos seguros es **tres**. Se distinguen nuevas revisiones y, en tendencias históricas que reutilizaron ID, episodios con fecha posterior **y texto factual diferente**. Revisar contexto, no solo `r0`.

Los trabajos `launch_only` confirmados pueden salir del índice activo aunque el raster siga generándose o esperando captura. El reparador reconcilia algunos jobs con `pc_launched_at` a LAUNCHED. No espera descarga ni certifica TTImages. Encolado y escritura en rama control usan push fast-forward como exclusión entre pasadas; un conflicto exige releer, no forzar un job sobre otro.

### 15.2 Imagen creada, imagen registrada e imagen entregada

| Prueba | Qué demuestra | Qué queda por comprobar |
|---|---|---|
| job + command_id | Solicitud persistida | PC la consumió y envió |
| `pc_picked_up_at` | Listener recogió orden | Prompt realmente enviado |
| `pc_launched_at` / LAUNCHED | Bridge confirmó lanzamiento | Imagen terminada, calidad y archivo |
| Imagen visible en ChatGPT Images | Generación disponible en ese contexto | Captura/descarga y envío PC |
| Fichero raster local con metadatos | Descarga/captura | Entrega TTImages y correspondencia ID/revisión |
| Recibo de envío del relay | Entrega por PC confirmada | Que una tarjeta/registro de app concreto esté enlazado, si ese flujo lo exige |

La validación de IA registrada comprueba proveedor/origen, URL, dimensiones y huella. Noticias exige metadatos `chat-imagegen`, `executing_chat`, mínimo **1024×576**, URL y SHA no vacíos. Tendencias además valida SHA-256, bytes locales y dimensiones reales de la imagen de repositorio. El canal `launch_only` puede dejar una imagen en Images sin completar esos campos. **No equiparar ninguna de esas pruebas con las demás.**

La selección automática de estilo usa hash de ID/revisión/intento/**command_id**: estable para ese trabajo; un intento nuevo puede variar. El botón nativo Copiar GAG tiene su propio generador. Si salen cartelas/texto, comparar el prompt del job real con el del botón; arreglar uno no prueba que cambió el otro.

### 15.3 Archivo real y sus límites

Noticias: el reparador busca `og:image`, `twitter:image` o `image_src` en páginas fuente y comprueba respuesta de imagen; guarda `source_url`, fuente, `generated:false` y habitualmente `rights_status:unverified`. Tendencias: `trends/enrich_explained_images.py` ordena fuentes y valida raster/fallback; mantiene el canal archivo separado de IA y no debe pisar una IA válida.

**Una foto encontrada no tiene sus derechos comprobados por encontrarla**, ni `ready` corrige ese dato. Hay discrepancia entre las aspiraciones del manual y verificaciones técnicas más laxas —por ejemplo, `valid_archive()` de noticias comprueba URL/no generada y puede aceptar HTTP—. Leer los campos reales antes de declarar una foto apta para uso. Las apps disponen de catálogo de `archive-images/`; Windows admite además algunos fallback HTTPS. Un catálogo vacío no prueba que el texto editorial esté mal.

Histórico confirmado el 16/10: TTImageRelay **V2.6.1**, captura cada 5 min y actualización controlada de galería cada 10 min; solo novedades, con huellas y 38 exclusiones iniciales. Ruta `%LOCALAPPDATA%\TTImageRelay\App_v2\relay-captura.js`; logs `relay-captura-v2.log` y `Telegram\telegram-v2.log`. **Versión/horarios instalados el 29/10 no verificados en esta revisión**. No reinstalar esa versión histórica por el mero hecho de estar documentada.

## 16. Qué sigue sin PC, vigilancia y diagnóstico de atascos

| Operación | Dependencia del Windows local |
|---|---|
| Radar, agrupación y selección en GitHub Actions | No requiere PC encendido; sí Actions y fuentes accesibles. |
| Borrar/desestimar/reelaborar desde iPhone a GitHub | El handler persiste sin listener PC; la redacción posterior es otro tramo. |
| Pasada directa en una conversación activa | Puede cerrar texto sin el launcher PC si tiene acceso suficiente a GitHub y fuentes. |
| Trigger inmediato consumido por listeners | Requiere Windows, listener, sesión ChatGPT y Chrome 9223 operativos. |
| Imagen automática vía ImageBridge | Requiere ese consumidor local y compositor/sesión válidos. |
| Captura/envío TTImages | Requiere el relay local y Chrome 9234. |

`tt-autorepair.yml` coordina cada **5 min** auditoría, guardia editorial, detección y limpieza técnica. **No redacta, investiga ni arregla por sí solo cualquier pestaña rota.** `shared/tt_editorial_run_guard.py` declara ventana de inicio **5 min**, espera entre solicitudes **15 min**, ACK activo **12 min**, gracia de cierre **5 min**, máximo **tres solicitudes por conjunto de pendientes**. Reporte: `telegram/editorial-run-guard.json`. Autoheal: enfriamiento **15 min**, escalado editorial **20 min**; estado `telegram/tt-autoheal-state.json`. Parte de sus comprobaciones mantiene compatibilidad con ledgers Telegram antiguos; contrastar cualquier alerta con decisiones y flujo nativo.

Los dos listeners dedicados tienen **backoff editorial 10 min** ante fallo de envío; sus estados locales guardan command_id y próximo reintento. No interpretar esa espera como cola perdida. Logs en `C:\TTiTTulares\ttittulares-mobile-trigger.log` y `ttendencias-mobile-trigger.log`; estados `*-mobile-trigger-state.json`. `TT-AutoUpdater.ps1` declara intervalo **120 s**, valida hash/sintaxis y actualiza una lista cerrada de listeners/bridges/watchdog/watcher; **no incluye `Ejecutar.js` ni TTImageRelay ni las apps instaladas**. Tener updater activo no prueba tener actualizado el launcher local.

### 16.1 Primera transición ausente: orden obligatorio de lectura

1. **Un elemento concreto:** proyecto, ID, revisión y episodio, hora Madrid, acción y dispositivo.
2. **Origen:** aparece en radar/Top30 o existe petición manual; fuentes y frescura válidas.
3. **Selección:** estado activo en cola y fuente autoritativa; si no entra, motivo preciso de descarte/dedup.
4. **Solicitud/consumo:** trigger en control, command_id, ACK del mismo comando y log del listener.
5. **Envío real:** mensaje en conversación correcta; distinguir target accesible de envío confirmado.
6. **Resultado:** outbox/cierre directo, revisión, validaciones, run aplicador y escritura en main.
7. **Listas:** preparado/explicación y request coherentes; ningún terminal o revisión posterior que lo oculte.
8. **Acción app:** request_id → recibo aplicado/rechazado → decisión → refresco de snapshot completo.
9. **Visual independiente:** job → prompt → raster → fichero PC → envío TTImages.

No empezar por reiniciar todo. Si el texto ya está persistido y la app no lo ve, investigar filtros/versión/lectura. Si no existe outbox, investigar el editor antes del aplicador. Si la imagen está creada, investigar captura/entrega antes de volver a generarla.

### 16.2 GitHub rojo, en cola o «atascado»

El listado de Actions recuperado el 29/10 incluía fallos de `ttittulares-image-enrich.yml` y `ttendencias-image-enrich.yml` y ejecuciones correctas del reparador actual de Explicadas. Los dos primeros contienen definición retirada/no-op; su fallo **no prueba fallo del generador vigente**. No se investigó su error concreto ni se repararon en esta tarea.

Comprobar por **workflow, run_id, rama, SHA, hora, status y conclusion**, además del job/step. Las claves de concurrencia son distintas: radar, refresh, outbox, reparadores y coordinador; muchos declaran `cancel-in-progress:false`. La existencia de concurrencia puede serializar trabajos; **no demuestra por sí sola la causa de un atasco**. Revisar cuál está realmente queued/in_progress y cuánto lleva, sin cancelar lotes o reenviar órdenes en masa.

### 16.3 Ejemplos históricos para evitar falsas reparaciones

- **Orden iPhone publicada pero «por confirmar»:** `7024c36e404e` r1 ya tenía published, recibo applied y ledger; `READY` histórico en processing no la convierte en pendiente. Comparar revisión del recibo, no publicar otra vez.
- **Fátima:** tendencia `be8d15b587e1` y noticias `ce01210bb2ef`/`7ca2e207fd62` son IDs distintos. No resolver por nombre aproximado.
- **Imagen sin compositor:** `0372e00a6665`, `0f6c1f39d248`, `e1be1212607a` se documentaron READY con IA fallida y archivo de derechos no verificados el 29/10 por la mañana. Son antecedentes, **no estado actual comprobado**.
- **Chrome 9223 responde pero el launcher falla:** `ERROR: Target crashed` identifica fallo de interacción/target; no demuestra pérdida del JSON. Un recuperador bloqueado por runner activo actuó correctamente; no forzarlo por defecto.
- **Usuario dijo «Creo que ya funciona todo»:** confirmación general recuperada en la conversación del 29/10; no certifica versión instalada, cada ruta de imagen ni estabilidad sostenida. Mantener ese matiz al registrar el incidente.

### 16.4 Avisos, badge, lectura y operaciones múltiples

`pilot/listas_transition_alerts.py` + `ttactualidad-listas-alerts.yml` avisa por proyecto cuando Listas pasa **0 → positivo**, con baseline inicial silencioso; no avisa por cada nueva ficha si ya había pendientes. Puede recuperar un intervalo cero perdido si lo demuestra con fechas/decisiones, sin inventarlo desde una lectura parcial. El cron declarado es **03,13,23,33,43,53 UTC**; también hay push/dispatch/workflow_run. Los commits hechos con GITHUB_TOKEN no siempre disparan otros push workflows: comprobar el encadenamiento explícito y el cron.

La entrega utiliza ntfy y enlaces `ttactualidad://noticias` / `ttactualidad://tendencias`; los secretos de tema no se incluyen en esta memoria. Si no se recibe aviso, distinguir: transición realmente ocurrida, estado persistido en `pilot/ttactualidad-listas-alert-state.json`, outbox/ACK de notificación y apertura de app. Aviso/badge/Live Activity no producen elaboración ni publican contenido. En iPhone la actualización de Live Activity depende además de las restricciones de ejecución de iOS.

La fuente iPhone incluye selección múltiple/reelaboración conjunta (`EditorialBatchSheet.swift`, dispatch `ttactualidad_batch_v1`) y conserva estado de leídos/pendientes. **La presencia del botón no demuestra que su workflow receptor esté desplegado en main:** el árbol consultado sitúa `ttactualidad-ios-batch.yml` y `pilot/ttactualidad_batch.py` en la rama iOS, ausentes del árbol principal de este corte. Registrar esa divergencia para diagnóstico, sin afirmar que la operación múltiple funciona en producción ni corregirla durante una investigación documental.

## 17. Cómo mantener esta memoria útil

Tras cada cambio, actualizar **en el mismo trabajo** la ruta, estados, responsable, condición de entrada/salida, archivos y pruebas afectados; añadir incidente con síntoma, causa probada/hipótesis, commit, despliegue/instalación y resultado real. Si solo compiló o se persistió código, escribir eso. Si falta la prueba de PC/iPhone, conservar el pendiente visible.

Para el próximo fallo basta empezar con la ficha LEER-PRIMERO y un ID/captura/error; este manual permite localizar las fuentes. **No promete recordar automáticamente todos los cambios futuros ni diagnosticar un PC sin sus señales actuales.** No es necesario reenviar todas las conversaciones: facilitar el enlace canónico o el archivo completo y la evidencia del nuevo fallo.

**Fuentes de esta ampliación:** los archivos enlazados en el índice de fuentes de la copia completa, los dos documentos históricos leídos y las conversaciones recuperadas. Las afirmaciones de código corresponden al corte indicado; las comprobaciones físicas/producción conservan su fecha y grado de verificación.


**Fin de memoria. Actualizar esta referencia junto con la evidencia de cada cambio.**


## 18. Agrupar tendencias de Listas — 30/10/2026

- **Petición del usuario:** botón Agrupar revisa todas las tendencias de Listas; crea una ficha publicable por acontecimiento concreto. La aclaración posterior exige **conservar intactas las explicaciones originales**, sin copiarles el texto nuevo.
- **UI:** iPhone 0.4.23 build 29, basada en 0.4.22, rama `feature/ttactualidad-ios-0.4.23-agrupar-listas`; Windows Qt también incorpora Agrupar y Retirar agrupadas. La instalación en dispositivos debe confirmarse aparte de compilar.
- **Solicitud:** dispatch `ttactualidad_group_listas_v1`, decisión `group_listas`, UUID. `pilot/listas_grouping.py` valida Listas vivas, guarda snapshots exactos y crea un request `listas_grouping_request:true`, `task:group_listas` en requests/cola normal. Conserva textos y estado de las candidatas mientras se investiga; recibo estándar por request_id. Repetir una solicitud no abre dos trabajos simultáneos.
- **Investigación:** mismo runner editorial TTendencias. El nuevo bloque del contrato prioriza estas solicitudes y exige acontecimiento común comprobado, no similitud de nombres. Resultado en `trends/listas-grouping-outbox/<job_id>.json`; workflow `ttactualidad-group-listas.yml` consume push/cron */5/dispatch.
- **Aplicación:** revalida ID/revisión y hash del texto de cada miembro. Crea otra ficha `listas_group_role:joint` con texto nuevo; originales siguen explained y reciben solo `listas_group_role:covered`, `covered_by_id`, `covered_by_name`, fecha/vínculo de agrupación. No modifica su explicación, remate, explained_at, revisión o imágenes. Una edición/borrado concurrente invalida el grupo completo, sin resurrecciones.
- **Visibilidad y publicación:** Listas muestra la conjunta y las originales con distintivo Agrupada en…; las originales quedan al final en iPhone/Windows y se desactiva su publicación. El backend rechaza marcar una cubierta como published, también desde un cliente anterior. No existe publicación automática en X.
- **Limpieza:** Retirar agrupadas envía `remove_covered` con los IDs/revisiones seleccionados; solo cierra originales cubiertas vigentes como deleted, conserva la conjunta y no incrementa publicaciones. También se puede retirar cada original con su botón habitual.
- **Cierre:** job `grouping_completed`, IDs conjuntos y grupos omitidos por cambios en `grouping_skipped_stale`. Si no hay relaciones, groups:[] cierra la revisión sin tocar fichas. Un resultado inválido deja `needs_correction`/error y permite corregir el mismo outbox; no representa éxito.
- **Pruebas:** 11 pruebas sintéticas de backend (texto preservado, JIT, deduplicación, limpieza y protección del handler); 44 pruebas de datos/UI Windows; preflight iOS. La suite histórica `test-ttactualidad-direct-actions.py` conserva cuatro errores de fixtures/interfaces que se reprodujeron también con el código base sin cambios; no se alteró ese legado para ocultarlos. Ver compilaciones de la entrega para la validación de binarios.
