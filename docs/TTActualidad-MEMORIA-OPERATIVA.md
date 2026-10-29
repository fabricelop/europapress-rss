# TTActualidad — memoria operativa integral y manual de rescate
**Revisión base: 29 de octubre de 2026.** Repositorio: **fabricelop/europapress-rss**. Este documento recoge arquitectura verificada contra código y decisiones de nuestras conversaciones. Es un **documento vivo**, no una garantía de salud en tiempo real.

**Antes de una avería, abrir primero [LEER PRIMERO](TTActualidad-LEER-PRIMERO.md).** Guardar también [INCIDENTES Y DECISIONES](TTActualidad-INCIDENTES-Y-DECISIONES.md). Este manual se debe actualizar después de cada cambio en los componentes.

## 1. Principios obligatorios

1. **Identificar el sistema exacto** antes de tocar nada: app **iPhone nativa SwiftUI**, app **Windows nativa Qt**, backend GitHub/Windows/Cloudflare para editorial e imágenes, o la **web antigua**. La última NO es el código de las apps nativas.
2. **Main de GitHub es la autoridad de datos editoriales**; la rama control es autoridad de triggers y algunos trabajos de imagen; los logs Windows son autoridad sobre lo que realmente ejecutó el PC. Un mensaje antiguo o una captura no sustituyen una relectura actual.
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
- Umbral automático: **mínimo 4 fuentes generales independientes** con evidencia del mismo hecho. Candidato que no crece permanece en radar esperando dentro de la ventana de unas **24 h** del contrato (verificar expiración efectiva en código). Revalidar, no contar titulares copiados como corroboración.
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
6. Persistencia por **TTITTULARES_OUTBOX_V1** en comentario del **issue #164** (también PR #2) o fichero en **ttittulares/editorial-outbox/**. Procesos **ttittulares/ingest_pr_outbox_comment.py**, **ttittulares/apply_editorial_outbox.py**; workflows **ttittulares-outbox-comment-ingest.yml**, **apply-ttittulares-outbox.yml**. Valida revisión, longitud, texto y decisiones terminales antes de actualizar.
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
- La selección Top10 debe atenderse aunque cambie la posición, sin saltarse solicitudes manuales ya registradas.

### 4.2 Elección de tendencias
- **trends/auto_queue_new.py**, **trends/requests.json**, **trends/editorial-queue.json**. **Top 10**: explicar automáticamente las no explicadas y reexplicar cuando caduca la explicación de **48 horas**. **11–30: únicamente Preparar/reexplicación explícita**; nunca seleccionar de oficio la siguiente 11–30.
- **Fuera del Top 30**: no entrar por ranking automático, pero una petición con pistas hecha por el usuario debe preservar ID, revisión y contexto aunque se mueva o salga del radar.
- Estados: **preparing**, **update** (nueva versión), **problematic** (bloqueo), **explained**, **grouped**, **inactive**, **deleted**, **published**. Una desaparición del Top 10 no equivale a borrar una petición manual.
- Agrupar solo tendencias que inequívocamente describen **un mismo hecho**: group_id, group_leader_id, trend_names y trend_context. Se usa explicación canónica, pero **cada request/estado** debe quedar reconciliado y no se borra ficha del usuario por deduplicación automática.
- Existe función **Tendencia → TTiTTulares** para un acontecimiento noticioso concreto, actual y verificable; no asumir que toda tendencia se transforma en noticia sin decisión o ejecución de handler. Triggers/criterios en **pilot/apply-ttactualidad-action.py** y configuración de puente.

### 4.3 Elaboración y cierre explicado
1. Cuando la cola se ha escrito a main, **trends/request_pc_editorial.py --trigger** escribe **trends/run-now-trigger.json** en la rama control y ejecutor **pc_chat_ttendencias_dedicated**.
2. **windows/TTendenciasDedicatedListener.ps1** lee trigger/ACK, lanza **Ejecutar.js tendencias --enviar** con **TTENDENCIAS_EDITORIAL_JOB_V2**; leer primero **trends/editorial-run-prompt.md**.
3. El editor trata cada **preparing / update** vigente en orden con barrera JIT **(id,revision)**, investiga hecho verificable y no confunde el nombre de una tendencia con su causa. No generar ImageGen en la pasada editorial.
4. **explanation** copiable: **TT#N nombre literal es tendencia porque...**, línea de **2–3 hashtags específicos**, y remate único **🌶️** al final salvo casos sensibles que admiten cierre factual sin chiste. Menos de **280 caracteres ponderados según X**. **closer_text** contiene solo la línea 🌶️ (o vacío cuando corresponde). No duplicar cabecera TT#N en la app. Remates originales, un solo concepto, puntuación separada de texto.
5. Persistir **exactamente la misma explicación y revisión** en **trends/requests.json** y **trends/telegram-manual-explained.json**; eliminar de **trends/editorial-queue.json** solo las revisiones realmente completadas. Aplicadores: **apply-ttendencias-chat-outbox.yml** (PR #7), **ttendencias-editorial-apply.yml** y reconciliador **ttendencias-editorial-reconcile.yml**, **trends/apply_direct_reconcile.py** cuando procede.
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
- Variación de estilos definida de forma determinista por ID/revisión, entre cómic europeo, retro, pop art, cartoon 3D, stop-motion, novela gráfica y caricatura sofisticada. La prueba final es **visual**; un prompt correcto no impide por completo un fallo de ImageGen.
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

**Fin de memoria. Si algo cambia, actualizar este documento junto con su prueba, no dejar el cambio solo en una conversación.**
