# TTiTTulares V2 — contrato de datos y arquitectura

**Paso 2 del roadmap: diseño versionado.** Este documento no implementa ni autoriza la ejecución del sistema.

## 1. Objetivo

Reconstruir el flujo de noticias con la arquitectura probada de TTendencias V2, conservando las reglas y resultados útiles de TTiTTulares V1, pero sustituyendo las colas históricas, el listener residente, el chat persistente y la sesión Chrome compartida.

Habrá dos consumidores autónomos:

- **Editorial:** una noticia/revisión → un trabajo → Chrome y chat nuevos → investigar/redactar → validar → persistir y releer → cerrar el chat y el Chrome propio.
- **Imagen:** una noticia/revisión READY → trabajo separado → otro Chrome y chat nuevos de ChatGPT Images → generar/capturar → validar/asociar → releer → cerrar el chat y el Chrome propio.

Sus colas, leases, intentos, diarios y estados son independientes. Un fallo o espera de imagen no bloquea READY ni la redacción de otras noticias. Una imagen nunca se asocia a una revisión distinta.

## 2. Principios obligatorios

1. event_id identifica un acontecimiento concreto durante toda su vida. No se deriva del titular, de una URL aislada ni de la posición del radar.
2. revision empieza en 1 y solo aumenta por novedad material verificada, corrección factual o reelaboración explícita. Añadir fuentes o mover puestos no crea revisión.
3. Acontecimiento, revisión, job editorial, job de imagen, imagen, decisión humana y recibo de publicación son entidades distintas.
4. Los registros READY finalizados son inmutables. Corregir/reelaborar crea otra revisión y conserva la anterior.
5. Los índices de cola son proyecciones reconstruibles. El archivo individual del job es la autoridad de su estado, lease, envío y resultado.
6. Cada operación tiene un ID e idempotency key. Un reintento no duplica jobs, imágenes, decisiones ni publicaciones.
7. Antes de abrir un chat, enviar, capturar, persistir o asociar se relee el estado exacto de event_id + revision (JIT).
8. Envío confirmado no equivale a respuesta capturada; captura no equivale a READY; prompt de imagen no equivale a original guardado; publish request no equivale a publicación confirmada.
9. Si el envío a ChatGPT es ambiguo, recuperar la misma conversación o marcar incidencia. Nunca reenviar a ciegas.
10. Cada job crea y posee su perfil/proceso Chrome. Solo cierra el chat y Chrome que él mismo abrió. Nunca toca Chrome de V1, TTendencias ni otros workers.
11. URLs privadas de ChatGPT, cookies, tokens y detalles de sesión quedan en diario local protegido; GitHub solo conserva referencias opacas y hashes.
12. READY y la generación de imagen nunca publican automáticamente. Hace falta acción humana explícita y recibo verificable.

## 3. Identidad y revisiones

| Campo | Contrato |
|---|---|
| event_id | ID opaco V2 con prefijo ttn2- y 24 hexadecimales. Se crea una vez y se conserva. |
| revision | Entero monotónico por acontecimiento. |
| editorial_job_id | Un job lógico por event_id + revision; se deriva de ambos. |
| image_job_id | Un job lógico de imagen por event_id + revision; separado del editorial. |
| command_id | Identifica cada envío concreto a ChatGPT; nuevo valor por intento real. |
| run_id | Identifica una invocación de worker. |
| decision_id | Identifica una decisión humana inmutable e idempotente. |
| receipt_id | Identifica un intento/resultado de publicación. |
| media_id | Identifica un original raster por su huella SHA-256. |

V2 no reutiliza automáticamente IDs V1. Una migración individual, solo cuando se autorice, puede conservar legacy.v1_event_id como referencia. No se importará masivamente el backlog V1.

**No crea revisión:** nueva fuente del mismo hecho, variación del radar, repetición de feed, cambio de titular equivalente o movimiento de puesto.

**Crea revisión:** evolución material del mismo acontecimiento verificada de forma independiente, corrección factual sustantiva o petición expresa de RE/RE-X. El texto y la imagen anteriores permanecen en su revisión original.

**Crea otro event_id:** hecho posterior distinto, aunque comparta persona, institución o tema. La deduplicación compara hechos concretos, URLs normalizadas y fingerprints; ante duda, no fusiona automáticamente.

## 4. Archivos canónicos propuestos

Todo se guarda bajo v2/ttittulares/ en feature/ttactualidad-v2-clean.

~~~text
state/radar/current.json
state/radar/scans/<scan_id>.json
state/radar/source-health.json
state/news-index.json
state/editorial-queue.json
state/image-queue.json
news/<event_id>.json
jobs/editorial/<editorial_job_id>.json
jobs/images/<image_job_id>.json
records/<event_id>/r<revision>.json
images/<event_id>/r<revision>/<sha256>.<ext>
images/manifests/<event_id>-r<revision>.json
decisions/<event_id>/<decision_id>.json
publication-receipts/<event_id>/r<revision>/<platform>/<receipt_id>.json
~~~

**Autoridad:** news/<event_id>.json conserva identidad/revisión actual; jobs/* son autoridad del estado de ejecución; records/* son READY inmutables; images y manifests conservan originales; decisions y publication-receipts son auditoría append-only. state/*queue.json y state/news-index.json son índices/proyecciones reconstruibles.

No crear un JSON gigante con toda la hemeroteca o con bytes de imagen. Separar un job por archivo reduce las colisiones entre workers. Los commits relacionados deben ser atómicos en el árbol Git y usar compare-and-swap con expected_sha. Ante conflicto: releer, validar JIT y volver a calcular; nunca forzar ni rebasar a ciegas.

## 5. Radar, fuentes y agrupación

Cada scan tiene scan_id y observed_at. Guarda salud por fuente (tipo, familia, hora de consulta, latencia, resultado/error, última consulta correcta, racha de fallos y recuento de elementos), y apariciones (título original, URL, published_at si existe, detected_at y fingerprint).

Se conserva el contrato auditado de V1:
- umbral automático normal de **cuatro familias generales independientes**;
- cuatro URLs de la misma familia no son cuatro votos;
- fuentes discovery ayudan a encontrar/agrupar, pero no suman al umbral general;
- cinco feeds deportivos están configurados en V1, pero la política de voto de una noticia cubierta solo por fuentes deportivas debe cerrarse al portar el radar; no se infiere del número de feeds;
- propuesta manual puede investigar con menos fuentes o cero iniciales, pero no certifica el hecho: para READY debe existir verificación;
- los candidatos automáticos sin umbral caducan tras 24 h;
- una vez creado el trabajo editorial, la variación del radar no lo cancela ni reemplaza.

Una fuente caída no invalida todo el barrido: se prueban sus fallbacks y siguen trabajando las demás. Una aparición solo cuenta una vez por familia independiente. No guardar artículos completos ni extractos extensos; conservar enlaces y evidencias mínimas de qué hecho respalda cada fuente.

## 6. Job editorial

Estados permitidos:
- pending: listo para reclamar.
- claimed: lease vigente; aún no se ha enviado.
- send_intent: prompt preparado y envío en curso.
- awaiting_response: envío confirmado.
- capture_recovery: el envío pudo ocurrir; recuperar el chat exacto.
- captured: respuesta completa capturada.
- validating: contraste factual y validación de formato.
- persisting: escritura de READY y verificación.
- ready: resultado persistido y releído correctamente.
- problematic: incidencia que requiere reparación/decisión.
- superseded: existe una revisión superior.
- cancelled: cancelación explícita y motivada.

phase informa de la actividad concreta (browser_starting, chat_starting, researching, drafting, remate_selection, verifying, persisting, closing_browser); no sustituye el estado del job.

### Lease e intentos

El claim exige worker_id, hash de token, started_at, heartbeat_at, expires_at y coincidencia JIT de event_id/revision. Lease inicial propuesto: 15 minutos, renovable. La capacidad editorial y la capacidad de imagen se configuran separadamente; los workers pueden avanzar en paralelo, con un governor global de recursos del PC. No se fija aún un número definitivo de workers.

Al expirar:
- sin send_intent: se puede reencolar si queda presupuesto de intentos seguros;
- con envío confirmado o incierto: capture_recovery, sin volver a mandar;
- sin posibilidad de identificar la misma conversación: problematic/manual_only.

Presupuesto inicial propuesto: hasta tres fallos demostrablemente anteriores al envío. El número de claims, fallos de preflight y envíos reales se contabilizan por separado. Cada reenvío autorizado tiene command_id nuevo.

### Ciclo de una noticia

1. JIT del job/evento/revisión.
2. Crear perfil Chrome aislado y chat nuevo.
3. Escribir diario local protegido con run_id, command_id, target_id y referencia privada de chat.
4. Enviar prompt e identificar el marcador exacto.
5. Investigar, contrastar y redactar en ese chat.
6. Capturar respuesta completa.
7. Cerrar chat y Chrome propios y verificar que no quedan procesos/targets del job.
8. Validar contenido, fuentes, hashtags, remate y longitud.
9. Persistir records/<event_id>/rN.json y releer para comprobar ID, revisión y SHA.
10. Solo entonces cerrar el job como ready.

Un fallo al cerrar Chrome no se oculta como éxito: se registra como error de limpieza y se resuelve sin tocar procesos ajenos. La captura y el cierre de recursos se verifican incluso si luego falla la persistencia.

## 7. Registro editorial READY

El registro inmutable de una revisión contiene:
- event_id, revision, título y URL canónica;
- factual_summary y explanation;
- tweet.text, tweet.remate, hashtags y character_count;
- fuentes citadas y evidencia por fuente;
- source_count, drafted_source_count y verified_source_count;
- selection_mode, reason, radar_scan_id y verificación factual;
- editorial_job_id, editorial_sha256 y prepared_at.

Se mantiene el contrato V1 auditado: un tuit por noticia, máximo 256 caracteres completos, dos hashtags concretos como norma (tres solo si caben), remate específico cuando realmente exista. Si no hay remate apto, tweet.remate es vacío, se registra no_remate_reason y el texto termina en los hechos/hashtags sin frase de relleno. No inventar cifras, responsables, declaraciones ni causas.

Cada fuente indica qué hecho respalda. Una excepción manual al umbral se identifica expresamente y nunca permite presentar como confirmado un hecho que no se ha podido verificar.

El registro READY no contiene bytes ni data URLs de imagen. La imagen se referencia mediante un manifest separado. La ausencia de imagen no cambia READY.

## 8. Job de imagen independiente

Solo se encola después de READY, contra el registro exacto y con editorial_sha256 congelado. No reabre ni reutiliza el chat editorial; no investiga ni reescribe la noticia.

Estados: pending → claimed → send_intent → generating → captured → validating → persisting → saved. También capture_recovery, problematic, superseded y cancelled.

Ciclo: JIT del registro → crear otro perfil Chrome y chat nuevo de ChatGPT Images → enviar prompt basado solo en la revisión persistida → capturar original → cerrar chat/Chrome propios → validar → guardar archivo por SHA → manifest por event_id/revision → readback.

La asociación exige coincidencia de event_id, revision, editorial_sha256, image_job_id, command_id y SHA-256. MIME permitido: PNG/JPEG/WebP. Dimensiones mínimas propuestas: 1024×576. El primer original válido de esa revisión queda fijado; un resultado posterior no lo reemplaza silenciosamente.

Una revisión nueva tiene su propio job de imagen. Una imagen r1 nunca se presenta como r2. Un fallo de imagen no devuelve READY a PROCESSING ni crea incidencia editorial. El tratamiento visual será gag editorial cuando proceda y sobrio/rigurosamente contextual en temas sensibles. No inventar víctimas, escenas o hechos. La guindilla es exclusivamente tipográfica y no se dibuja.

La política única de encolado automático, regeneración y excepciones visuales se definirá antes de activar el consumidor; la auditoría V1 detectó políticas contradictorias.

## 9. Decisiones y publicación

Las acciones humanas son eventos append-only con decision_id, event_id, revision, actor, occurred_at, action e idempotency_key.

Acciones: dismiss, delete, request_rework, mark_published, publish_request y restore. Una reelaboración no modifica el READY anterior: crea revision+1 con alcance explícito (reinvestigate, factual_correction, text_rewrite o remate_only) e instrucciones.

D1 del Worker privado recibe acciones con idempotency key y estado de aplicación; GitHub conserva el registro editorial y la copia durable de la decisión ya aplicada. La interfaz no declara éxito hasta comprobar el readback. Si falla la aplicación, la acción permanece pendiente/error visible.

La publicación requiere click/orden humana explícita. Cada plataforma y cada intento tienen receipt_id propio y estado requested, submitting, confirmed, failed, uncertain o cancelled. Solo confirmed o un mark_published explícito permite reflejar la noticia como publicada. Guardar el ID y URL externa cuando estén disponibles. Nunca almacenar tokens/cookies en documentos.

Si la respuesta de publicación es incierta, consultar primero el canal; no publicar de nuevo a ciegas.

## 10. Diarios, privacidad y recuperación

Cada run tiene diario append-only: timestamps, fase, event_id/revision, command_id, hashes de prompt/respuesta, observación de envío, captura, persistencia, cierre de Chrome y error codificado.

La URL privada del chat, target_id y ruta de perfil pueden estar en el diario local protegido, nunca en GitHub. El repositorio almacena session_id opaco, conversation_url_sha256 y private_journal_id. No registrar cookies, tokens ni datos de autenticación. Un intento anterior nunca se sobrescribe.

Un envío ambiguo intenta recuperar la misma conversación. Un error antes de enviar puede reintentarse dentro del presupuesto seguro. Si no se puede demostrar que no se envió, no se crea otro chat para repetir el prompt.

## 11. Web privada y fronteras V1→V2

La página Noticias tendrá En elaboración, Listas, Incidencias, Historial y recibos de publicación. Editorial e imagen mostrarán actividad e incidencias separadas. Los estados e iconos son proyecciones del estado autoritativo.

| V1 auditado | Contrato V2 |
|---|---|
| radar_no_d1.py y events | radar V2, snapshots y salud propios |
| editorial-processing.json | cola V2 + jobs editoriales por archivo |
| auto_queue.py | selector V2 de candidatos |
| treated_news.py | news-index y fingerprints por hecho |
| editorial-run-prompt.md | prompt editorial V2 portado selectivamente |
| listener + Ejecutar.js + Chrome persistente | worker editorial V2 y chat/Chrome efímeros |
| TTITTULARES_OUTBOX_V1 / issue #164 | persistencia V2 con CAS y readback |
| prepared.json / status.json | registros READY inmutables y proyecciones |
| ImageBridge / TTImages V1 | image worker V2 separado |
| decisiones del panel | acciones D1 idempotentes y decisiones aplicadas |
| publicación V1 | petición explícita + recibo por plataforma/intento |

No usar colas, tokens, estado ni procesos V1 como backend o fallback de V2. No importar automáticamente noticias pendientes de V1.

## 12. Puertas de aceptación

Antes de implementar workers, probar:
1. Mismo hecho en distintas URLs → mismo event_id; hechos distintos del mismo protagonista → IDs distintos.
2. Cuatro URLs de una familia no superan el umbral; cuatro familias independientes sí.
3. Repetición o movimiento del radar no crea revisiones.
4. Novedad material crea mismo event_id y revision+1 conservando READY anterior.
5. Dos workers concurrentes no obtienen el mismo lease.
6. Una respuesta tardía r1 no puede cerrar r2.
7. Envío ambiguo → capture_recovery, sin reenvío automático.
8. Falta de readback → no READY.
9. Fallo de imagen → READY intacto.
10. Imagen de otro evento/revisión/hash → asociación rechazada.
11. El cierre de un job no termina procesos de otro worker ni V1.
12. Decisión D1 duplicada no crea dos decisiones/publicaciones.
13. Publish request no es receipt confirmado.
14. CI no escribe en main, no ejecuta ChatGPT/Chrome y no publica.

## 13. Decisiones aplazadas y siguiente paso

Quedan por fijar al implementar: número de workers y presupuesto global de Chrome al coexistir con TTendencias; cadencia exacta del radar; política de fuentes exclusivamente deportivas; encolado automático/reintentos de imagen; retención de fotos de archivo y procedimiento de migración individual.

**Paso 2 — contrato de datos y arquitectura: diseñado.** El schema y el bundle de ejemplos que acompañan este documento muestran los documentos principales y sus relaciones.

**Siguiente paso: radar/ingesta V2 aislado.** Portar y probar funciones puras de fuentes, familias, filtros, agrupación, TTL, identidad y novedades materiales. El radar debe crear candidatos propios, sin leer ni escribir colas V1.

Hasta aprobar pruebas y validación E2E, efectos externos y publicación permanecen desactivados.