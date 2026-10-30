# TTActualidad — memoria operativa completa

**Estado funcional de referencia: 30/10/2026.** Repositorio `fabricelop/europapress-rss`. Este manual describe un único funcionamiento vigente, integrado por procesos. El historial de cambios e incidentes se conserva por separado en `docs/TTActualidad-INCIDENTES-Y-DECISIONES.md`.

El manual permite localizar cada eslabón y los datos que prueban su resultado. No es un informe de salud en tiempo real: antes de reparar hay que releer el estado remoto y comprobar qué versión está instalada.

## 1. Objetivo y reglas del sistema

TTActualidad permite al editor controlar noticias y tendencias, investigar su causa, preparar explicaciones y escoger qué publicar en sus cuentas X. La publicación es manual. El usuario declara un límite de **51 publicaciones por cuenta en las últimas 24 horas móviles**; el contador le ayuda a administrar ese cupo. Es una restricción de sus cuentas, no una afirmación universal sobre X.

- La interfaz es **iPhone nativa SwiftUI** y **Windows nativa Qt**. La web antigua y sus Workers no son las apps nativas.
- **main de GitHub** es la fuente de verdad editorial. Las ramas `control/*` contienen disparadores, ACK y jobs. Los logs del PC prueban qué se ejecutó allí. Una conversación o captura antigua no sustituye la lectura actual.
- Correlacionar siempre **proyecto + ID + revisión + request_id/command_id + fecha Europe/Madrid**. Las decisiones terminales y revisiones posteriores prevalecen sobre resultados tardíos.
- Una solicitud, un ACK de lanzamiento, un mensaje enviado, un outbox, un texto persistido, una imagen generada, una descarga y una publicación son resultados distintos.
- El texto llega a Listas por validación editorial; no espera IA, archivo ni Telegram. En tendencias, la imagen espera además a la decisión de agrupación del texto exacto.
- No se dan ni solicitan estrellas a comentarios/remates. Los ficheros de ratings conservados son históricos y no autorizan reactivar esa función.
- Sí existe la acción manual **Enviar a TTiTTulares** desde tendencias: crea otra investigación, conserva su origen y no convierte automáticamente el texto en noticia verificada.
- Conservar FabCalendar, SeLoRecordamos, URGENTE, TTImages, RainETA, otros servicios y credenciales. No reiniciar Chrome ni procesos por intuición. No introducir servicios de pago para resolver una avería sin una decisión expresa.

## 2. Componentes, versiones y propiedad

| Componente | Fuente / lugar | Función y prueba |
|---|---|---|
| iPhone | `ios/ttactualidad/TTActualidad/*.swift` | Lectura GitHub, UI, acciones y caché; no sustituye decisiones remotas |
| Fuente iOS de esta entrega | `feature/ttactualidad-ios-0.4.28-revision-y-grupos`, 0.4.28 build34 | Comprobar IPA e instalación; main puede contener una fuente iOS anterior |
| Compilación | `.github/workflows/ttactualidad-ios.yml` | Pruebas nativas y build app + Live Activity; IPA sin firmar para PlumeImpactor |
| Windows Qt | `desktop/ttactualidad/TTActualidad_Moderno.pyw` | GitHub directo; distribución preferida ZIP sin EXE, distinta del antiguo Tkinter |
| Decisiones | JSON de `main`, `pilot/ttactualidad-action-receipts.json` | Estado aplicado y recibos por petición |
| Contador | `pilot/ttactualidad-publication-events.json` | Publicaciones declaradas explícitamente por el editor |
| Control noticias | `control/ttittulares-run-trigger` | Trigger editorial, ACK y trabajos de imagen de noticias |
| Control tendencias | `control/ttendencias-run-trigger` | Trigger editorial, ACK y trabajos de imagen de tendencias |
| Envío editorial PC | `windows/*DedicatedListener.ps1`, `C:\TTiTTulares\Ejecutar.js` | Mensaje a ChatGPT por Chrome CDP9223; Ejecutar.js es local, no presumir actualización desde GitHub |
| Lanzamiento IA | `windows/TTiTTularesImageBridge.js`, `TTendenciasImageBridge.js` | Prompt en ChatGPT Images, modo launch_only |
| Captura y entrega | `%LOCALAPPDATA%\TTImageRelay`, Chrome CDP9234 | Descarga al PC y envío a TTImages |
| API de control | `https://tt-control.fabricelop.workers.dev` | Comandos/ACK/jobs para listeners; no es la UI nativa |
| Web anterior | `docs/ttactualidad/index.html`, `pilot/ttactualidad-live/` | Legado; desplegarlo no actualiza iPhone ni Qt |

Autenticación: los clientes usan GitHub para operaciones editoriales y deben obtener recibos reales. Un HTTP204 solo acredita recepción del dispatch. No incluir tokens, temas privados ntfy ni URLs firmadas en esta memoria. Antes de editar la app, identificar la rama que produjo el IPA instalado y conservar las funciones posteriores a la fuente antigua de main.

## 3. Radar y selección de noticias TTiTTulares

`telegram/radar_no_d1.py` declara **19 medios generales**, **5 deportivos** y **3 entradas de descubrimiento**. Generales: Europa Press, EL PAÍS, La Vanguardia, Cadena SER, RTVE, El HuffPost, 20minutos, ABC, COPE, EFE, Servimedia, elDiario.es, Público, El Mundo, Antena 3 Noticias, laSexta Noticias, Onda Cero, Telecinco Noticias y Noticias Cuatro. Deportivos: AS, MARCA, Mundo Deportivo, SPORT y EFE Deportes. Descubrimiento: Reuters Radar, AP Radar y Público · Tremending.

El código trata Antena 3/laSexta/Onda Cero como **una** familia Atresmedia y Telecinco/Cuatro como **una** familia Mediaset. Por tanto hay **16 familias generales según este mapa**, no 19 fuentes independientes a efectos del umbral. Los deportivos y el descubrimiento ayudan a detectar/agrupar, pero **no cuentan para las cuatro familias generales**. Este mapa es la implementación comprobada, no una auditoría completa de propiedad o independencia editorial de todos los medios.

Captura mediante RSS/HTML y fallbacks por medio, con recuperación Google News por dominio y ventana retrospectiva. Guarda cada aparición, URL, título, tipo de fuente, familia y fechas. Consolida titulares del mismo hecho y depura apariciones discordantes antes de declarar elegible. Un contador cuatro tras agrupar no basta si la evidencia no corresponde al mismo hecho.

`WAITING` / `UPDATE_WAITING` → consenso de ≥4 familias → `ELIGIBLE` / `ELIGIBLE_UPDATE`. Una revalidación puede devolver a WAITING un evento que pierda evidencia al depurar o consolidar. En modo actual `web`, este paso no envía aviso editorial Telegram. El mínimo de salud declarado es **14 medios generales**; no confundirlo con el umbral cuatro ni con el total configurado.

### Antirrepetición y actualizaciones

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

### Entrada a elaboración

`ttittulares/auto_queue.py` selecciona los elegibles, aplica `treated_news.py` y deja la revisión PROCESSING en **las dos colas**: `telegram/editorial-processing.json` y `ttittulares/editorial-queue.json`. `ttittulares/status.json` es resumen, no autoridad única. Una noticia manual puede entrar con cero fuentes para investigar; eso no permite cerrarla sin verificación.

El radar no redacta. `redaccion-ttittulares.yml` y los handlers manuales solicitan una pasada del editor. Si no aparece una noticia, comprobar primero elegibilidad, historia similar concreta, edad, filtros y terminales; no rebajar el umbral de fuentes a ciegas.

## 4. Elaboración y cierre de noticias

1. El trigger de `control/ttittulares-run-trigger` identifica el comando. `windows/TTiTTularesDedicatedListener.ps1` lo consume, comprueba cola activa y lanza `Ejecutar.js ttittulares --enviar` con `TTITTULARES_EDITORIAL_JOB_V2` mediante la variable temporal `TT_CHAT_MESSAGE_B64`.
2. El PC debe confirmar envío real a la conversación correcta. `Ready` del Programador, Chrome accesible o ACK launched no prueban redacción. `Target crashed` identifica un fallo de interacción, no pérdida de JSON.
3. El editor lee `ttittulares/editorial-run-prompt.md`, la cola, processing y status. Trata PROCESSING/rewrite_pending con barrera JIT por event_id/revisión. No genera IA en esa pasada.
4. Verifica el hecho y redacta tuit completo con factual, dos hashtags específicos (tres si caben), y remate 🌶️ al final cuando corresponde. El contrato de noticias fija **≤256 caracteres**; `tweet.remate` guarda solo el remate. No trasladar automáticamente ese límite a tendencias, que usa ponderación X.
5. La entrega editorial usa `TTITTULARES_OUTBOX_V1` en comentario del **issue #164**. **PR #2 es control/telemetría**, no destino de nuevos outboxes. Los aplicadores de archivo heredados siguen existiendo como infraestructura; no crear una ruta paralela por comodidad.
6. `ttittulares/ingest_pr_outbox_comment.py` y `apply_editorial_outbox.py`, con sus workflows de ingesta/aplicación, validan revisión, texto y decisiones antes de escribir `ttittulares/prepared.json` READY y retirar la revisión de las colas.
7. Releer main: prepared con texto, fecha y revisión correctos y sin terminal ni revisión posterior. Solo entonces cuenta como cerrada. Falta de imagen no invalida READY.

El progreso durable se sigue en runtime/RUNTRACE. Un 0/0 no basta cuando existe trabajo activo en la cola autoritativa. Si el editor dejó texto en otro sitio pero no en prepared, sigue pendiente la aplicación. Una duplicada requiere cierre persistido con referencia al original y motivo, no solo una explicación en el chat.

## 5. Radar y selección de tendencias TTendencias

`trends/update_trends.py` captura rankings de 13 agregadores públicos: trends24, getdaytrends, tweets24, superx, twtdata, snaplytics, whatstrends, cyberkendra, xtrendsiamrohit, trendswe, xtrendssaroj, playersells y fowtools. No asumir acceso al ranking interno oficial de X por API.

Normaliza para comparar mayúsculas/acentos/etiquetas conservando el nombre visible. Compara fecha y antigüedad de cada fuente, diversidad y consenso. Una fuente sin fecha requiere corroboración. Una descarga nueva puede contener un ranking viejo. `trends/recent.json` registra captura, método, fuentes, Top30, movimientos y señales; `checkpoint.json` y el watchdog respaldan frescura. Ante fallo, conservar el último radar identificado como tal, sin inventar actualidad.

**Todas las pendientes/azules del Top30, puestos 1–30, entran automáticamente en elaboración** mediante `trends/auto_queue_new.py`, con `auto_queue_scope:top30`. No hay una franja 11–30 reservada a preparación manual. Los puestos 31+ y señales Próximas tendencias no se seleccionan por ranking. La captura debe ser fiable; mantener las barreras de fuente insegura.

La selección conserva trabajo ya aceptado al cambiar de puesto, solicitudes manuales, pistas, revisiones y decisiones terminales. Los ámbitos históricos top10/next_unexplained_11_30 identifican el origen de antiguas solicitudes; no cambian la regla Top30 actual.

Los estados principales son preparing, update, problematic, explained, inactive y terminales published/deleted/dismissed/removed. `grouped` y group_leader_id pueden aparecer en datos históricos; la agrupación vigente de Listas usa cobertura explícita y conserva originales.

Una explicación vieja no se renueva solo por cumplir 48h. La revisión de novedades determina si sigue válida, necesita actualización o corresponde a otro episodio. Los terminales no se reabren; un acontecimiento posterior verificado usa identidad nueva.

## 6. Elaboración ordinaria de tendencias

La cola autoritativa es `trends/editorial-queue.json`, coordinada con `requests.json`. `trends/request_pc_editorial.py --trigger` solicita la misma pasada en la rama control, con ejecutor `pc_chat_ttendencias_dedicated`. El listener `windows/TTendenciasDedicatedListener.ps1` lanza `Ejecutar.js tendencias --enviar` con `TTENDENCIAS_EDITORIAL_JOB_V2` y el contrato `trends/editorial-run-prompt.md`.

Orden de trabajo: investigaciones nuevas y reelaboraciones manuales vigentes primero; agrupaciones después; revisiones rojas después. Las problemáticas ordinarias se reintentan al final mientras sigan en Top30. Cada paso relee ID/revisión y respeta cierres concurrentes. Un job especial de agrupación/revisión no es una tendencia llamada como su título.

Investigar el detonante actual con fuentes verificables. `user_pistas` e `hints_verification_status:unverified` se conservan como hipótesis; mantener `investigation_history`. No asumir que una pista del editor está comprobada. Tras dos búsquedas distintas sin detonante verificable, guardar problematic con razón concreta y continuar; nunca inventar causa, actualidad o remate para vaciar la cola.

El formato habitual es `TT#N <nombre literal> es tendencia porque <hecho>`, línea de dos hashtags específicos (tres si aportan precisión y caben) y un único remate 🌶️ al final cuando corresponde. El **tuit completo tiene menos de280 caracteres ponderados X**, URLs23. `explanation` contiene todo el tuit copiable; `closer_text` solo la línea 🌶️ o vacío cuando procede. No duplicar cabeceras, etiquetas o remate. No dar estrellas ni usar ratings para decidirlo. Mantener estilo, verificación, sensibilidad y reglas editoriales del usuario.

Persistir la misma explicación, closer_text, explained_at, ID y revisión en `requests.json` y `telegram-manual-explained.json`. Un registro solo en requests no está terminado. Retirar únicamente la revisión cerrada de la cola y releer ambos documentos. La nueva explicación queda `editorial_grouping_state:pending` para la decisión visual posterior; ya puede aparecer como texto en Listas.

Transporte: cierre directo verificado, comentarios `TTENDENCIAS_CHAT_OUTBOX_V1` en PR#7 o outbox heredado aplicado por `ttendencias-editorial-apply.yml`. Los reconciliadores `shared/ttendencias_queue_reconcile.py`, `trends/reconcile_prepared_ready.py` y `apply_direct_reconcile.py` conectan rutas existentes. Preservar metadatos de mantenimiento al reconstruir la cola; no tratar una comprobación especial como un ready ordinario.

La pasada deja RUNTRACE canónico `TTENDENCIAS_RUNTRACE_V1` en PR#7 y runtime durable en `trends/editorial-runtime.json`, con run_id, fase, mensaje, IDs/revisiones y resultado real. Delegar a un trigger sin consumidor/RUNNING no equivale a ejecutar la investigación. La IA tiene lifecycle separado y no forma parte del cómputo de texto cerrado.

## 7. Revisión automática de tendencias rojas

El color depende de **explained_at**, no de la última comprobación: verde menos de12h, amarillo de12h a24h inclusive, rojo más de24h. Una comprobación sin novedades no vuelve verde una explicación antigua.

`pilot/trend_maintenance.py`, invocado por `pilot/listas_grouping.py` en `ttactualidad-group-listas.yml`, selecciona las rojas que siguen en un Top30 fresco. La captura debe tener como máximo una hora de antigüedad y no estar marcada insegura. Cada origen admite una revisión activa y un intervalo mínimo de una hora desde la última comprobación. Las nuevas investigaciones tienen prioridad; una cola ordinaria activa aplaza el mantenimiento.

El job conserva el origen intacto en `review_source` (ID, revisión, explicación, fecha, fingerprint), tiene `red_review_request:true`, `task:review_red` y viaja por la misma cola, trigger y editor habituales. Las publicadas pueden servir de origen para novedades, conservando su terminal. Las retiradas/desestimadas no se reabren automáticamente por antigüedad.

| Resultado de investigación | Persistencia | Efecto visible/publicación |
|---|---|---|
| Sin novedad material | outcome unchanged; conservar texto y explained_at; actualizar red_review_checked_at, motivo y fuentes | «Revisada · sin novedades»; conserva color por edad |
| Novedad sustancial verificada | outcome updated; fuentes y new_facts; nueva ficha `trend-update-*` con ID independiente | Nueva propuesta en Listas, todavía sin publicar |
| No se puede verificar | outcome unverified y razón concreta | Conserva explicación previa y muestra el motivo de revisión sin verificar |
| Snapshot cambiado, cierre nuevo o revisión posterior | review_outcome stale | No sobrescribe ni resucita el origen |

La salida es `trends/maintenance-outbox/<job_id>.json`; se aplica transaccionalmente con JIT. Un error se guarda en `review_error` y se corrige en el mismo resultado. La mera persistencia del outbox no completa la revisión: comprobar `review_completed` y la ficha real.

Para continuidad, la nueva explicación usa **«sigue siendo tendencia por…»**, o plural **«siguen siendo tendencia por…»**. Si se demuestra un acontecimiento distinto —otro partido, resolución o episodio días después— se indica `distinct_episode:true`, se explicita qué lo hace diferente y se usa «es tendencia por…». Ni edad, subida de puesto, etiquetas sinónimas ni artículos que repiten lo sabido bastan para otra publicación.

La ficha nueva vuelve a pasar por agrupación antes de pedir IA. Si la anterior aún no estaba publicada y seguía en Listas, puede quedar marcada cubierta conservando su texto; si estaba publicada, se conserva terminal e historial. La revisión no suma publicaciones. El editor decide si publica la nueva y lo confirma explícitamente.

## 8. Agrupación automática y selección manual

**Finalidad:** un acontecimiento comprobado debe tener una propuesta conjunta y una imagen, evitando gastar varias publicaciones en etiquetas del mismo hecho. Similitud de persona, partido, programa, palabra o tema no prueba identidad de acontecimiento. Ante duda, mantener separadas.

### Planificación automática

Cuando no queda investigación ordinaria preparing/update, el planificador compara las fichas elegibles de Listas no cubiertas, incluyendo las ya existentes que puedan relacionarse con una nueva. Un fingerprint de ID, revisión, fecha y explicación identifica qué texto ya pasó la comparación. Las fichas sin clearance permanecen pendientes de agrupación para nuevas imágenes; el texto sigue disponible.

Crea un job `listas-auto-*`, `listas_grouping_request:true`, `automatic_grouping:true`, `task:group_listas`, con `grouping_candidates` exactos y `published_context` reciente. Una candidata única también se compara con publicaciones previas. Un mismo job puede encontrar varios grupos o ninguno. El workflow corre por cambios relevantes, despacho y cron de5min, sujeto a retrasos de Actions; solicita la pasada editorial habitual, no un segundo motor IA.

### Resultado y conservación

El editor guarda `trends/listas-grouping-outbox/<job_id>.json`. Cada grupo contiene nombre, explicación, remate si procede, motivo, fuentes y al menos dos miembros del snapshot con su revisión. El aplicador relee el estado actual y compara sus hashes; si un miembro cambió o fue quitado, omite ese grupo entero. Los restantes pueden aplicarse; registra `grouping_skipped_stale`.

Crea una ficha nueva `listas-joint-*`, `listas_group_role:joint`, con los miembros y fuentes. Las originales mantienen íntegros explicación, remate, fecha, revisión e imágenes; solo reciben `listas_group_role:covered`, covered_by_id/name/revision, covered_source_revision, covered_at y grouping_request_id. Se ven como **Agrupada en…**. Una revisión posterior no hereda cobertura de la anterior.

Si ya existe una publicación reciente del mismo acontecimiento y no hay hechos nuevos, `covered_by_existing` puede vincular una nueva etiqueta a esa publicada sin crear otra propuesta o imagen. La publicación debe pertenecer al snapshot y seguir válida al aplicar; no basta un nombre parecido ni la mera declaración de haber publicado. Si hay novedades, debe prepararse la actualización correspondiente.

Un resultado `groups:[]` completa la comparación sin agrupar. Solo las candidatas del snapshot que siguen intactas reciben `editorial_grouping_state:cleared` y `editorial_grouping_fingerprint` válido. Las llegadas durante la investigación esperan la siguiente comparación. Las conjuntas nuevas quedan autorizadas para su imagen; las originales cubiertas se excluyen. Los jobs ya lanzados antes no se cancelan desde este proceso.

Ante `grouping_error` / needs_correction, corregir el mismo outbox. No liberar imágenes fingiendo éxito ni crear solicitudes duplicadas. El job final es grouping_completed con IDs creados. Las reglas no publican, no borran originales y no alteran el contador.

### Botón Agrupar de Listas

En iPhone, **Agrupar abre una selección de tendencias**. Se necesitan al menos dos; el dispatch `ttactualidad_group_listas_v1` lleva exclusivamente sus IDs y revisiones. El servidor rechaza una selección obsoleta o una agrupación ya en curso, en lugar de ampliar silenciosamente a todas las Listas. Sirve para pedir una agrupación que el sistema no haya detectado. El backend no acepta una orden manual vacía como escaneo global.

Las originales conservan **Quitar de Listas → Sí, publicada / No publicada**. La conjunta permanece. **Retirar agrupadas** retira en bloque únicamente originales cubiertas seleccionadas y vigentes, sin contar otra publicación. No confundir ese cleanup con confirmar published ni con borrar la conjunta.

La selección manual de esta entrega está implementada en iPhone; no asumir que el cliente Qt instalado tenga el mismo selector. El proceso automático sí es común a ambos porque modifica el estado remoto.

## 9. Listas, estados, sincronización y acciones

| Vista/objeto | Fuente principal | Condición de entrada/salida |
|---|---|---|
| Noticias Listas | ttittulares/prepared.json | Texto READY vigente, sin terminal ni rework posterior |
| Tendencias Listas | trends/telegram-manual-explained.json + requests | Explained vigente, sin terminal ni revisión posterior; ventana visible48h |
| En elaboración noticias | Cola compacta válida y processing detallado | PROCESSING/UPDATE_PROCESSING; excluir READY de la misma o posterior revisión |
| En elaboración tendencias | editorial-queue + requests vigentes | Preparing/update ordinarios o jobs especiales reales; cierre exacto |
| Top30 | trends/recent.json + explicaciones/historial | Ranking actual independiente de estar en Listas o publicada |
| Pendientes | Radar/peticiones sin explicación verificable | No confundir fallo de verificación con texto listo |
| Órdenes por confirmar | Operaciones locales + recibos remotos | La solicitud persiste hasta applied/already_applied/rejected confirmado |

Una cola compacta válida y vacía significa cero trabajo. Solo usar status como fallback cuando falta una estructura válida, no cuando count es0. Una lectura fallida no prueba una cola vacía. Un READY histórico no cierra un rework posterior; un PROCESSING histórico tampoco reabre un READY vigente.

Con elaboración, órdenes pendientes o esa vista abierta, iPhone consulta cada60s mientras puede ejecutarse. El botón Solicitar procesamiento espera la lectura en curso, consulta antes de pedir y refresca después. Si el estado fresco demuestra cero pendientes, lo informa sin lanzar otro comando; petición registrada y texto cerrado se muestran como resultados diferentes. Las operaciones optimistas prepare/rework desaparecen cuando main muestra la revisión objetivo terminada, aunque no se haya visto la fase intermedia.

Filtros TTendencias: **Top30, Listas, En elaboración, Recientes, Pendientes y Antiguas**, en dos filas de tres. No existe Nuevas. Todas las tendencias incluyen **Buscar en X**, con nombre literal en `q` y `f=live`, codificado por URLComponents; disponible también sin explicación, agrupadas y conjuntas. Buscar no publica, no encola y no requiere autorización editorial GitHub.

Acciones editoriales: `GitHubEditor.swift` envía dispatch; `pilot/apply-ttactualidad-action.py` aplica por revisión JIT e identidad de petición. `pilot/ttactualidad-action-receipts.json` contiene applied/already_applied/rejected. Los tombstones están en `ttittulares/decisions.json` o `trends/mobile-decisions.json`; conservarlos. Una caché de dispositivo no puede prevalecer sobre un terminal confirmado.

Reelaborar/Reexplicar crea una revisión y conserva historial/contexto. Aportar pistas inicia investigación exacta con instrucciones, sin dar las pistas por verificadas. Copiar texto/GAG/foto son acciones de copia; Publicar en X abre un borrador. Ninguna acredita que se haya publicado.

### De tendencia a noticia

En la fuente iPhone contrastada `EditorialActionPanels.swift` muestra **«Enviar a TTiTTulares»** y confirma **«¿Investigar esta tendencia como noticia?» → «Enviar a En elaboración»**. `sendTrendToNews()` calcula un UUID estable desde `ttactualidad-trend-news:<ID>:r<revision>`: repetir el toque/reintento de esa revisión reutiliza la identidad. Crea operación local «De tendencia a noticia», con ID `manual-<UUID>`, y consulta Órdenes pendientes. Una revisión posterior puede generar una solicitud diferente.

`GitHubEditor.addNews()` envía `ttactualidad_manual_news_v1` con proyecto TTiTTulares, título «Investigar noticia: …», instrucciones de contraste y `origin_trend:{id,revision,name}`. **No copia automáticamente la explicación como noticia verificada**: la incluye como contexto preliminar. La tendencia sigue en TTendencias y no se publica ni se borra por esta acción.

En el backend, `.github/workflows/ttactualidad-manual-news.yml` ejecuta `pilot/submit_ttactualidad_manual.py`. Verifica origen exacto en requests, catálogo histórico explicado/publicado o Top30 real; rechaza ID inventado, nombre distinto y revisión obsoleta. Puede aceptar una tendencia histórica auténtica aunque haya salido del ranking. Guarda `origin_project`, `origin_trend_id`, `origin_trend_revision`, `origin_trend_name` y crea **PROCESSING r1** en **las dos colas de noticias**. Es petición manual con cero fuentes iniciales permitidas para investigar, no permiso para inventar hechos.

El handler evita repetir el mismo event_id y detecta algunos duplicados de URL/título; escribe recibo `applied`, `already_applied` o `rejected`, con `existing_event_id` si hay otra noticia. El workflow persiste primero y después solicita al editor de TTiTTulares; si rechaza, no dispara una elaboración. Correlacionar recibo y cola: `applied` prueba la entrada, **no** el cierre READY posterior.

**Diferencia de clientes:** en el `.pyw` Qt de main revisado no aparece ese botón específico ni el payload `origin_trend`; sí existe «+ Noticia» genérico. No declarar paridad completa por compartir backend. La capacidad de pasar tendencias está comprobada en iPhone y backend; localizar versión/implementación Windows si se investiga su ausencia, sin negar la función global ni añadirla por esta tarea documental.

## 10. Publicación, contadores y avisos

El contador es por cuenta/proyecto y ventana de **24h móviles**, no día de calendario. Solo suma una confirmación explícita published aplicada con request_id único en `pilot/ttactualidad-publication-events.json`. Copiar, abrir X, agrupar, investigar, crear IA o retirar agrupadas no suma. Una misma petición reintentada es idempotente. Lo publicado fuera de TTActualidad no se descubre automáticamente por este ledger.

La decisión «Quitar de Listas» debe permitir indicar si se publicó. Sí registra published; No registra retirada sin publicación. Eso también se aplica a originales agrupadas, con la decisión real del editor. Retirar una original no borra la conjunta; publicar una conjunta no prueba que se publicaran individualmente todas sus originales.

`pilot/listas_transition_alerts.py` + `ttactualidad-listas-alerts.yml` avisa por proyecto cuando Listas pasa **0 → positivo**, con baseline inicial silencioso; no avisa por cada nueva ficha si ya había pendientes. Puede recuperar un intervalo cero perdido si lo demuestra con fechas/decisiones, sin inventarlo desde una lectura parcial. El cron declarado es **03,13,23,33,43,53 UTC**; también hay push/dispatch/workflow_run. Los commits hechos con GITHUB_TOKEN no siempre disparan otros push workflows: comprobar el encadenamiento explícito y el cron.

La entrega utiliza ntfy y enlaces `ttactualidad://noticias` / `ttactualidad://tendencias`; los secretos de tema no se incluyen en esta memoria. Si no se recibe aviso, distinguir: transición realmente ocurrida, estado persistido en `pilot/ttactualidad-listas-alert-state.json`, outbox/ACK de notificación y apertura de app. Aviso/badge/Live Activity no producen elaboración ni publican contenido. En iPhone la actualización de Live Activity depende además de las restricciones de ejecución de iOS.

Las acciones múltiples de `EditorialBatchSheet.swift` (`ttactualidad_batch_v1`) son diferentes de Agrupar Listas (`ttactualidad_group_listas_v1`). Verificar que el receptor concreto exista en main antes de diagnosticar una operación múltiple; no confundir una función presente en la rama iOS con un handler desplegado.


### Menú del icono y Live Activity

Al mantener pulsado el icono iPhone aparecen cuatro accesos dinámicos: Noticias listas, Tendencias listas, En elaboración de ambos proyectos y Órdenes por confirmar. Los números proceden de la última consulta canónica, con fecha/hora, no de una consulta permanente en segundo plano. Abrir la app una vez tras instalar actualiza los accesos. Sin datos conocidos no presentar ceros inventados; conservar la última lectura ante fallos parciales.

`HomeQuickActions.swift` modela y persiste el resumen (`TTActualidad.home-quick-actions.v1`), registra shortcutItems y retiene el destino hasta que SwiftUI esté listo. `TTActualidadApp.swift` instala delegados de app/escena para arranque frío y app abierta. El router consume cada selección una vez, limpia búsquedas y refresca el destino. Órdenes es un conteo local de ese iPhone, no de todos los dispositivos. El gesto no realiza acciones editoriales por sí mismo.

La extensión `TTActualidadLive.appex` sirve Live Activity y Dynamic Island; comprobar que PlumeImpactor firma app y extensión. Los números dependen de datos y restricciones de ejecución iOS; no son prueba universal de estado remoto actual.

## 11. Imágenes: decisión, lanzamiento, captura y entrega

| Etapa | Responsable / fuente | Resultado que prueba |
|---|---|---|
| Agrupación de tendencias | pilot/trend_maintenance.py + listas_grouping.py | Texto exacto autorizado para pedir imagen, sin cobertura por otra ficha |
| Elegibilidad noticias | repair-ttittulares-listas.yml | READY vigente para nuevo job visual |
| Elegibilidad tendencias | repair-ttendencias-explicadas.yml | Explained vigente, grouping cleared y fingerprint exacto, no covered |
| Solicitud IA | image-runs/jobs e index en rama control | Job persistido con target_id/revision/command_id |
| Consumo y prompt | Listener + ImageBridge + CDP9223 | picked_up y lanzamiento real en ChatGPT Images |
| Generación | ChatGPT Images | Imagen disponible en el contexto correcto |
| Captura | TTImageRelay + CDP9234 | Raster descargado al PC con correspondencia del item |
| Entrega | Relay desde PC → TTImages | Recibo de envío del PC |

No usar Actions para sustituir directamente la entrega de imágenes por el bot TTImages. No reinstalar ni cambiar Chrome9223/9234 sin identificar propietario, sesión y tarea activa. La pestaña y locks específicos se guardan en `C:\TTiTTulares\ttittulares-image-tab.json`, `ttendencias-image-tab.json` y sus `*-image-bridge.lock.json`.

El arte IA conserva el concepto del remate: una idea visual clara, 16:9, sin cartela con el tuit ni banda inferior por copiar texto editorial. La guindilla es solo marcador tipográfico del remate, no mascota u objeto que deba dibujarse. Sensibilidad exige enfoque sobrio. Copiar GAG nativo y prompt del bridge son generadores distintos: comprobar cuál produjo la imagen defectuosa.

### Elegibilidad e idempotencia

En tendencias se exige primero agrupación resuelta para el fingerprint del texto vigente y ausencia de cobertura por otra ficha. Las conjuntas pasan ese control al crearse; las individuales lo pasan al finalizar la comparación semántica. Los reparadores encolan IA para textos vigentes sin imagen válida, con fecha de entrada/explicación de **hasta 24 h**, respetando terminales y trabajos anteriores. En noticias el paso comprueba texto **y remate no vacío**; por tanto un READY sensible sin remate puede quedar fuera de esa ruta automática aunque la política general permita imagen sobria. **Registrar esta diferencia de implementación antes de atribuir el fallo a ChatGPT.** No cambiar el texto ni inventar un remate para forzar la imagen.

`shared/tt_image_idempotency.py` gobierna permisos de reencolado. `REQUESTED/RUNNING/GENERATING/PERSISTING/PICKED_UP/UNCERTAIN` y `DONE/LAUNCHED/READY/COMPLETED`, o cualquier marca `pc_submitted_at/pc_launched_at`, impiden repetir el mismo trabajo. Un ERROR tras recogida por PC puede coexistir con generación real: **no es prueba de que no se envió**. Un token de reintento manual no salta un job activo/lanzado.

Solo se permiten reintentos automáticos acotados cuando se demuestra que falló **antes del envío** —por ejemplo, el compositor no utilizable expresamente reconocido—, o una identidad editorial nueva. El límite habitual de reintentos seguros es **tres**. Se distinguen nuevas revisiones y, en tendencias históricas que reutilizaron ID, episodios con fecha posterior **y texto factual diferente**. Revisar contexto, no solo `r0`.

Los trabajos `launch_only` confirmados pueden salir del índice activo aunque el raster siga generándose o esperando captura. El reparador reconcilia algunos jobs con `pc_launched_at` a LAUNCHED. No espera descarga ni certifica TTImages. Encolado y escritura en rama control usan push fast-forward como exclusión entre pasadas; un conflicto exige releer, no forzar un job sobre otro.

### Pruebas por etapa

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

### Foto de archivo y relay

Noticias: el reparador busca `og:image`, `twitter:image` o `image_src` en páginas fuente y comprueba respuesta de imagen; guarda `source_url`, fuente, `generated:false` y habitualmente `rights_status:unverified`. Tendencias: `trends/enrich_explained_images.py` ordena fuentes y valida raster/fallback; mantiene el canal archivo separado de IA y no debe pisar una IA válida.

**Una foto encontrada no tiene sus derechos comprobados por encontrarla**, ni `ready` corrige ese dato. Hay discrepancia entre las aspiraciones del manual y verificaciones técnicas más laxas —por ejemplo, `valid_archive()` de noticias comprueba URL/no generada y puede aceptar HTTP—. Leer los campos reales antes de declarar una foto apta para uso. Las apps disponen de catálogo de `archive-images/`; Windows admite además algunos fallback HTTPS. Un catálogo vacío no prueba que el texto editorial esté mal.

El relay usa `%LOCALAPPDATA%\TTImageRelay\App_v2\relay-captura.js`; logs `relay-captura-v2.log` y `Telegram\telegram-v2.log`. La configuración documentada de referencia es V2.6.1, captura cada 5 min y actualización de galería cada 10 min, solo novedades con huellas/exclusiones. Verificar versión y tareas instaladas antes de intervenir: esa referencia no certifica el PC actual ni justifica reinstalarlo.


## 12. Tremending

**No confundir con el radar de tendencias ni con noticias autoelaboradas.** `tremending-collect.yml` corre en minutos **07,22,37,52 UTC**, además de dispatch/trigger. `ttittulares/tremending/update_tremending.py` revisa las primeras ocho páginas de Público/Tremending, desde la frontera **30/09/2026 00:00 Madrid** declarada, extrae artículos y tuits incrustados, deduplica URL canónica y persiste `ttittulares/tremending/items.json`.

La app muestra una bandeja de lectura. **No selecciona ni captura automáticamente tuits ni los envía a ninguno de los dos proyectos.** `tremending-capture.yml` es un no-op manual. Al borrar, el handler retira físicamente la entrada de `items.json` y conserva su URL en `scan.seen_urls`, además del registro pertinente de decisión; el recolector no la reintroduce. Si faltan embeds, conserva la pieza para reintentar su extracción.

## 13. Retirada, borrado y conservación

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
| Reelaborar/Reexplicar | Revisión nueva; tarjeta anterior deja de ser la vigente | Mantener identidad, historial, pistas; no heredar imagen sin verificar. |
| Tendencia explicada que deja el Top | Cambio de ranking independiente | No borrar petición manual ni su explicación por caer de puesto. |
| Tendencia en Listas con >48 h | Filtro temporal de UI la excluye | El histórico no se destruye; la revisión condicional debe comprobar las novedades antes de crear otro episodio. |
| Borrar/publicar tendencia | Terminal para episodio/revisión, sincronización de requests/catálogo/decisión | Un JSON explicado viejo no debe revivirla; revisión nueva no se borra desde una ficha antigua. |
| Original agrupada | Conserva explicación, marcada Agrupada en… | Retirada explícita; no suma publicación sin confirmación. |
| Borrar Tremending | Retirada física de items + URL en seen_urls | Evita que vuelva a entrar desde Público. |
| Job IA que sale del índice | LAUNCHED, cancelado o ya no elegible | Consultar `jobs/<id>.json`: índice vacío **no prueba ausencia de generación** ni autoriza repetirla. |
| Originales TTImages | Política histórica confirmada: limpieza cada hora de originales >**12 h**, incluso no enviados | Verificar que la tarea siga vigente; no borrar huellas, exclusiones, historiales ni decisiones. |
| Limpieza técnica Telegram | Solo IDs técnicos conocidos, recibidos hace **2 min–47 h** | `shared/tt_technical_cleanup.py`; nunca tarjetas editoriales, fijados o mensajes del usuario. |

**Tres acciones distintas:** copiar texto/foto no publica; abrir el borrador X no publica; la confirmación explícita Sí publicada registra publicación declarada. El ledger de TTActualidad no es por sí solo una auditoría de todo lo publicado fuera de la app en X.

Las fuentes históricas de rating, grupos antiguos y ledgers Telegram pueden seguir presentes para compatibilidad. No son instrucciones para volver a pedir estrellas ni para restaurar Telegram como bandeja editorial. Borrar datos históricos para que un contador cuadre destruye las barreras de repetidos y el diagnóstico.

## 14. Programaciones, Windows y vigilancia

| Proceso | Programación declarada UTC / inicio | Alcance |
|---|---|---|
| radar-no-d1.yml | :05/:15/:25/:35/:45/:55 | Captura noticias; no redacta |
| redaccion-ttittulares.yml | :15/:45 | Solicita editor noticias |
| ttendencias-refresh.yml | :07/:17/:27/:37/:47/:57 | Captura Top30 y encola pendientes1–30 |
| ttendencias-refresh-watchdog.yml | :08/:38 | Vigila frescura |
| ttactualidad-group-listas.yml | */5, push de resultados/datos y dispatch | Aplica mantenimiento, planifica agrupación/revisión y solicita editor habitual |
| ttendencias-editorial-reconcile.yml | */15 y dispatch | Reconcilia resultados ya escritos |
| apply-ttittulares-outbox.yml | */10 y push/dispatch | Aplica resultados, no los redacta |
| ttittulares-outbox-comment-ingest.yml | Comentario OUTBOX en issue164 | Ingesta noticias |
| apply-ttendencias-chat-outbox.yml | Comentario OUTBOX en PR7 | Ingesta tendencias |
| repair-ttittulares-listas.yml | */5 y push | Nuevos jobs visuales noticias |
| repair-ttendencias-explicadas.yml | */5 y push/dispatch | Archivo/reconciliación y nuevos jobs IA tras grouping |
| tt-autorepair.yml | */5 | Auditoría, guardia y solicitudes; no redacta |
| ttactualidad-direct-actions.yml | repository_dispatch | Decisiones editoriales |
| ttactualidad-manual-news.yml | repository_dispatch | Noticia manual / origen tendencia |
| tremending-collect.yml | :07/:22/:37/:52 | Recolector de lectura |
| ttactualidad-listas-alerts.yml | :03/:13/:23/:33/:43/:53 y eventos | Aviso de transición0→positivo |
| TTiTTulares Local / TTendencias Local | Tareas Windows cada15min | Dependen del listener/sesión/Chrome |

GitHub puede retrasar schedules. Sus cron son UTC; Windows y la UI se interpretan con Europe/Madrid y su horario de verano. Comprobar run_id, rama, SHA, status/conclusion y timestamp, no solo el nombre. Un commit con GITHUB_TOKEN no siempre dispara otro push workflow; las continuaciones explícitas y cron son importantes.

`tt-autorepair.yml` coordina cada **5 min** auditoría, guardia editorial, detección y limpieza técnica. **No redacta, investiga ni arregla por sí solo cualquier pestaña rota.** `shared/tt_editorial_run_guard.py` declara ventana de inicio **5 min**, espera entre solicitudes **15 min**, ACK activo **12 min**, gracia de cierre **5 min**, máximo **tres solicitudes por conjunto de pendientes**. Reporte: `telegram/editorial-run-guard.json`. Autoheal: enfriamiento **15 min**, escalado editorial **20 min**; estado `telegram/tt-autoheal-state.json`. Parte de sus comprobaciones mantiene compatibilidad con ledgers Telegram antiguos; contrastar cualquier alerta con decisiones y flujo nativo.

Los dos listeners dedicados tienen **backoff editorial 10 min** ante fallo de envío; sus estados locales guardan command_id y próximo reintento. No interpretar esa espera como cola perdida. Logs en `C:\TTiTTulares\ttittulares-mobile-trigger.log` y `ttendencias-mobile-trigger.log`; estados `*-mobile-trigger-state.json`. `TT-AutoUpdater.ps1` declara intervalo **120 s**, valida hash/sintaxis y actualiza una lista cerrada de listeners/bridges/watchdog/watcher; **no incluye `Ejecutar.js` ni TTImageRelay ni las apps instaladas**. Tener updater activo no prueba tener actualizado el launcher local.

La lectura de fuentes, selección, aplicación de decisiones y planificación de mantenimiento en Actions no requieren PC. La investigación a través del trigger sí requiere consumidor, sesión y conversación activa en Windows; una pasada directa en un chat con acceso suficiente puede cerrar texto sin ese lanzador. La IA automática necesita ImageBridge/CDP9223; la captura y TTImages necesitan relay/CDP9234. No confundir programar una solicitud con la ejecución real de ninguno de esos pasos.

## 15. Diagnóstico por primer eslabón ausente

| Síntoma | Primera evidencia | Siguiente comprobación |
|---|---|---|
| Radar noticias vacío/antiguo | events.json, status, run radar | Fuentes, fecha, independencia de familias |
| Cuatro fuentes y no entra | auto_queue logs + treated-stories | Mismo acontecimiento, actualidad, referencia exacta que bloquea |
| Top30 viejo | recent.json/checkpoint/runrefresh | Fecha real de cada fuente y consenso |
| Azul1–30 sin elaborar | auto_queue_new, requests, queue | Captura fiable, terminal/revisión y run selector |
| Muchas en elaboración | Cola viva → trigger/ACK | Listener → envío real → texto/outbox → aplicación |
| Solicitar procesamiento no cambia pantalla | Main fresco y revisión objetivo | Si ya hay READY, cliente/consulta/overlay; si no, tramo editorial real |
| Roja sin revisar | explained_at, recent actualizado, requests | >24h, sigueTop30, última revisión≥1h, trabajo nuevo prioritario, consumidor |
| Revisión marcada sin novedades | red_review_outcome/checked_at/sources | Color conserva edad original; no es fallo por seguir roja |
| Actualización no aparece | maintenance-outbox, review_error/job | JIT, superseded/stale, review_created_id, ficha explicada real |
| Agrupar no acaba | grouping job/outbox/grouping_error | Snapshot, miembros, fuentes, revisión aplicada, runner real |
| Imagen pendiente tras texto | grouping_state/fingerprint antes de image-runs | Si falta clearance, reparar agrupación; no lanzar por cada original |
| «Agrupada» no se puede quitar | Versión nativa y acciones de ficha | Quitar con Sí/No; cleanup remove_covered con recibo |
| No llega IA | Job control → PC log → Images → relay | Separar lanzamiento, generación, captura y envío |
| Imagen ya visible pero ausente en app | Raster/metadata/recibo relay | Correspondencia id/revisión y enlace, sin regenerar a ciegas |
| Enviar tendencia a noticias falla | manual-news receipt + origin_trend | Origen auténtico/revisión y dos colas noticias |
| Orden por confirmar pero dato aplicado | receipt + terminal + ledger | Revisión/request_id; cliente no debe publicar otra vez |
| Borrado reaparece | decisions/mobile-decisions, request, caché | Resultado tardío o revisión/episodio diferente; no borrar terminal |
| Cifra menú difiere | Hora del resumen canónico | Última consulta, lectura parcial, órdenes locales |
| Actions rojo | Workflow/run/rama/SHA/job/step | Flujos retirados image-enrich no prueban fallo del reparador actual |

Para un incidente: identificar un item, seguir origen → selección → solicitud → consumo → mensaje real → resultado → aplicación en main → vista → acción/recibo. Las imágenes se diagnostican luego por su rama independiente. No empezar reiniciándolo todo; una captura o un contador global no identifica el eslabón.

Si falta outbox, revisar editor antes de aplicador. Si el texto ya está en main, revisar cliente y filtros antes del editor. Si una imagen ya fue lanzada, revisar captura antes de solicitar otra. Si se demuestra una decisión terminal, conservarla aunque otro documento antiguo diga READY/preparing.

## 16. Verificación y mantenimiento de esta memoria

Los tests de agrupación y mantenimiento usan estados sintéticos: conservación de originales, selección exacta, revisiones obsoletas, cierres concurrentes, idempotencia, cobertura por una publicación, cooldown horario y bloqueo visual antes de clearance. Los tests Top30 comprueban puestos1–30, exclusión31+, manuales, cierres, radar inseguro y que edad sola no crea publicaciones. Los tests nativos cubren menú y seguimiento; el build compila app y extensión. Estas pruebas no acreditan instalación física ni una generación real de IA.

Después de cada cambio, integrar las reglas en sus apartados de proceso, responsables, entradas/salidas, rutas y diagnóstico. No añadir parches normativos contradictorios al final. Registrar síntoma, causa comprobada/hipótesis, commit, build e instalación en el historial separado. Verificar mediante relectura del ID/revisión real; distinguir código probado, persistencia, ejecución PC y prueba física.

## 17. Fuentes y acceso para otra conversación

Repositorio canónico: `https://github.com/fabricelop/europapress-rss`. Leer primero `docs/TTActualidad-LEER-PRIMERO.md` y este manual; consultar `docs/TTActualidad-INCIDENTES-Y-DECISIONES.md` para antecedentes. Contratos de redacción: `ttittulares/editorial-run-prompt.md`, `trends/editorial-run-prompt.md`. Para mantenimiento: `pilot/listas_grouping.py`, `pilot/trend_maintenance.py` y sus pruebas. Para versiones: project.yml, workflow de compilación, rama y artifact real; no asumir que main refleja el último IPA.

La copia completa para adjuntar a cualquier chat se llama `TTActualidad-Memoria-Completa-2026-10-29.md`; conserva ese nombre e identidad aunque el contenido se mantenga actualizado. El archivo describe contexto, no promete acceso automático universal ni vigilancia permanente del PC. Para reparar basta facilitarlo y añadir proyecto, ID/revisión, dispositivo, hora Madrid, acción y síntoma/error actuales. Los antecedentes de conversaciones no sustituyen la evidencia viva.
