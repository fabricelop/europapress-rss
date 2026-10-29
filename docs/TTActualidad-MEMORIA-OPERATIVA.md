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
