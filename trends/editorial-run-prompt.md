# TTendencias · contrato editorial vigente

Este contrato gobierna la misma pasada editorial iniciada por «Ejecuta TTendencias», el iPhone, Windows o su programación. La fuente de datos es `fabricelop/europapress-rss/main`; los triggers y jobs visuales usan `control/ttendencias-run-trigger`. Las instrucciones del usuario prevalecen. No publicar en X: el editor conserva siempre la decisión de publicación.

## Resultado y límites

El cierre editorial es texto verificado persistido en `trends/requests.json` y `trends/telegram-manual-explained.json`, con la revisión exacta retirada de `trends/editorial-queue.json`. READY/explained no espera fotos, IA ni Telegram. El panel editorial es TTActualidad nativa; Telegram editorial está retirado. TTImages es un transporte independiente desde el PC. No activar ImageGen, llamar al bot TTImages ni generar `trends/image-outbox/**` en esta pasada. Preservar FabCalendar, SeLoRecordamos, URGENTE, credenciales, sesiones y el Chrome de otros procesos.

Todas las pendientes del Top 30 (puestos 1–30) se investigan automáticamente. Las 31+ no entran por ranking. Las solicitudes manuales y pistas ya aceptadas se conservan aunque cambien de puesto o salgan del ranking. La edad por sí sola no autoriza otra publicación ni un nuevo episodio: las explicaciones requieren la revisión condicional de novedades descrita aquí.

## Inicio, orden y barrera de estado

1. Leer `trends/editorial-config.json`, `recent.json`, `requests.json`, `editorial-queue.json`, `telegram-manual-explained.json`, `mobile-decisions.json` y los últimos resultados de mantenimiento. La cola compacta vigente es autoritativa, incluso cuando está vacía. No resucitar trabajo desde resúmenes antiguos.
2. Correlacionar siempre proyecto, ID, revisión y fecha. Reconciliar textos ya persistidos con la revisión exacta; nunca por nombre solamente. Atender `rewrite_pending:true` si sigue vigente y no tiene una revisión posterior ni decisión terminal.
3. Procesar primero todas las nuevas investigaciones y reelaboraciones manuales `preparing/update`, de antiguas a recientes. Después, agrupaciones `task:group_listas`; después revisiones de novedades `task:review_red`. Las problemáticas ordinarias se reintentan al final si siguen en el Top 30. Releer la cola antes de cerrar: un trabajo nuevo puede haber llegado durante la pasada.
4. Justo antes de investigar, persistir o aplicar resultados, releer main y comprobar ID+revisión. Si el editor ha quitado, publicado, reelaborado o sustituido una revisión, respetar su estado. No borrar ni reabrir terminales; no sustituir textos más nuevos con snapshots de inicio. Una solicitud especial se completa mediante SU outbox, nunca convirtiéndola en una tendencia ficticia explicada.
5. El workflow `ttactualidad-group-listas.yml` mantiene las solicitudes especiales y se revisa cada cinco minutos, con posible retraso de Actions. Usa el mismo `trends/request_pc_editorial.py --trigger` y el mismo consumidor Windows. El trigger no demuestra ejecución: confirmar RUNNING real y resultado aplicado.

## Telemetría y ejecución real

«Ejecuta TTendencias» requiere ejecutar el trabajo en la conversación activa, no solo escribir un trigger. Delegar al PC únicamente si existe consumidor comprobado y ACK RUNNING. El PR #7 se usa para control, telemetría y transporte editorial; mantener el comentario canónico `TTENDENCIAS_RUNTRACE_V1` con `canonical:true` (verificar su ID actual, no crear uno por pasada).

Al iniciar actualizar el mismo RUNTRACE y `trends/editorial-runtime.json` con run_id, RUNNING, started_at, updated_at, current y total reales. Emitir fases reales `preparing`, `investigating`, `drafting`, `remate_selection`, `persisting`, `verifying`, `closing`, título, trend_id y mensaje concreto. En mantenimiento indicar «Revisando novedades», «Sin novedades», «Verificando acontecimiento común» o el motivo de bloqueo. No usar fases de generación de imágenes en el editor textual.

Al terminar persistir DONE/DONE_WITH_INCIDENTS o ERROR conforme al resultado real, finished_at y resumen de IDs/revisiones cerrados, revisiones sin novedades, actualizaciones, grupos y pendientes. Guardar `last_run` durable incluso con 0/0. No declarar éxito si falta persistir texto o aplicar un resultado tratado. Una cola vacía no prueba salud de imágenes. No solicitar estrellas ni usar ratings para escoger remates.

## Investigación ordinaria

Investigar por qué el término es tendencia AHORA. Contrastar fuentes actuales y fechas; distinguir el acontecimiento del que habla la gente del nombre de una persona, equipo o etiqueta. No usar capturas simultáneas, `batch_id`, palabras compartidas o partido político como prueba de un mismo acontecimiento. Las pistas `user_pistas` son hipótesis sin verificar; conservarlas con `investigation_history` y buscar corroboración independiente. No convertir una pista o rumor en hecho.

Tras dos búsquedas distintas sin poder verificar un detonante concreto, guardar `problematic` con motivo claro; no redactar una explicación inventada ni llenar con una definición genérica del término. Conservar el historial y continuar con otros trabajos. Las problemáticas del Top 30 pueden reintentarse en una pasada posterior, sin ocultarlas como resueltas.

Tremending conserva su prefijo `TT 🗯️`, origen trazable y circuito de tuit/foto real. No sustituir esa captura por una imagen inventada ni confundir este flujo con tendencias ordinarias.

## Redacción y remate

Mantener el estilo habitual del usuario. Para una primera explicación ordinaria:

```text
TT#N <nombre literal> es tendencia porque <hecho actual verificado>.
#EtiquetaEspecifica1 #EtiquetaEspecifica2
🌶️ <remate único>
```

Se admiten tres hashtags si aportan precisión y caben. No repetir un hashtag ya usado como nombre literal de cabecera. Evitar etiquetas genéricas, propaganda, especulación y hechos añadidos por el chiste. El tuit COMPLETO, con cabecera, hashtags, saltos y remate, debe tener menos de 280 caracteres ponderados X (URLs: 23). `closer_text` contiene únicamente la última línea `🌶️ ...`, o vacío cuando la omisión sea apropiada; no incluir hashtags en ese campo. No duplicar remate ni cabecera. El campo `explanation` es el tuit completo copiable.

Elegir un solo remate breve, concreto, original y ligado a hechos documentados, sin puntuaciones ni estrellas. Evitar repetir fórmulas recientes: consultar las últimas explicaciones y remates cuando sea necesario. **NORMA VISUAL PRIORITARIA 16/10/2026:** el emoji 🌶️ es únicamente un marcador tipográfico. Prohibido dibujar guindillas, chiles, pimientos picantes, su icono, silueta, logotipo o mascota; representar la idea del remate, nunca el emoji. Política: el remate seguro es obligatorio para completar la revisión, debe ser imparcial y sobre circunstancias verificadas; no convertirlo en consigna. No usar humor sobre víctimas, tragedias o sufrimiento. En asuntos sensibles y en los supuestos no políticos permitidos, cuando no corresponda o no exista uno adecuado, cerrar el texto factual con hashtags y `closer_text:""`; no bloquear indefinidamente un hecho verificado solo por el chiste. Mantener las reglas editoriales de sensibilidad del usuario.

## Persistencia ordinaria y Listas

Para cada tendencia redactar y guardar su propia explicación. La comparación semántica posterior crea las conjuntas sin reescribir originales. No usar el antiguo mecanismo que copia una explicación canónica a todas las requests o marca `grouped` y oculta miembros.

Persistir atómicamente en main la ficha `status:explained` en `telegram-manual-explained.json` y su request, con ID, revisión, explanation, closer_text y explained_at idénticos. Conservar fuentes verificadas y `editorial_grouping_state:"pending"`. El mismo contrato se aplica a una nueva revisión manual. Retirar solo el mismo ID/revisión de la cola después de releer ambos registros. Un texto en requests sin ficha no está terminado. Si falla una escritura, releer SHA y reparar la misma revisión sin redactar otra ni resucitar estados cerrados.

La ruta de transporte existente por comentarios `TTENDENCIAS_CHAT_OUTBOX_V1` en PR #7 y los reconciliadores siguen disponibles. En el modo heredado de `trends/editorial-outbox/<id>-r<revision>.json`, guardar texto/metadatos (`status:ready`, `prepared_item`) y comprobar que el aplicador `ttendencias-editorial-apply.yml` lo ha convertido en la ficha real. No incluir IA inline ni asumir que crear el outbox cierra el trabajo.

El botón manual «Enviar a TTiTTulares» sí existe: crea una investigación independiente con origen ID/revisión y conserva la tendencia. Esta pasada NO envía automáticamente tendencias a noticias; tampoco prohíbe la acción explícita del usuario.

## Agrupación antes de imágenes

Los jobs `listas_grouping_request:true`, `task:group_listas` llevan un snapshot exacto en `grouping_candidates`. Los automáticos tienen `automatic_grouping:true` y comparan Listas más `published_context` (publicaciones recientes). Los manuales contienen EXCLUSIVAMENTE las tarjetas que el editor seleccionó: no ampliar esa selección buscando otras fichas ni confundirla con una revisión global.

Buscar coincidencias inequívocas de un mismo acontecimiento actual. La mera coincidencia de persona, palabra, programa o tema no basta. Ante duda, dejar separadas. Crear una nueva explicación publicable por grupo de al menos dos miembros, con una sola cabecera, dos o tres hashtags y un único remate cuando proceda. Si es una actualización continuada, usar «sigue siendo tendencia por…» o «siguen siendo tendencia por…». No cambiar texto, remate, fecha, revisión ni imágenes de las originales. No publicar en X.

Guardar SOLO el resultado en `trends/listas-grouping-outbox/<job_id>.json`:

```json
{"job_id":"ID_DEL_JOB","groups":[{"name":"Acontecimiento común","explanation":"TT#2 ...\n#Etiqueta1 #Etiqueta2","closer_text":"","reason":"Hecho común contrastado","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}],"members":[{"id":"ID1","revision":0},{"id":"ID2","revision":1}]}],"covered_by_existing":[]}
```

Los ejemplos de URL son marcadores, nunca fuentes para copiar. Los miembros deben pertenecer al snapshot, ser disjuntos y mantener revisión y hash de texto. Si no hay coincidencias, escribir `groups:[]`; eso también es un resultado útil y desbloquea las imágenes de fichas individuales comprobadas.

Si una nueva etiqueta describe exactamente un acontecimiento YA publicado sin hechos nuevos, el job automático puede marcar cobertura sin crear otra publicación:

```json
{"job_id":"ID_DEL_JOB","groups":[],"covered_by_existing":[{"member":{"id":"ID_NUEVO","revision":0},"published_id":"ID_DEL_PUBLISHED_CONTEXT","no_material_changes":true,"reason":"Mismo acontecimiento ya cubierto, sin novedades sustanciales verificadas"}]}
```

No usar esa cobertura si hay novedades sustanciales ni si falta una publicación vigente del snapshot. No modificar la publicación histórica. El aplicador verifica JIT y crea fichas `listas_group_role:joint`; marca originales `covered` / «Agrupada en…», conservando sus textos. Los grupos obsoletos se omiten enteros en `grouping_skipped_stale`. Ante `grouping_error`, corregir el MISMO outbox; no crear jobs duplicados. Releer que el job terminó `grouping_completed` y que las fichas previstas están guardadas.

Solo las fichas con `editorial_grouping_state:cleared` y `editorial_grouping_fingerprint` correspondiente al texto exacto continúan hacia nuevas imágenes. Las originales cubiertas no piden una imagen adicional. Las imágenes ya lanzadas previamente no se cancelan desde este editor. Ni esta espera visual ni una agrupación fallida bloquean el texto ya disponible en Listas; registrar la causa y corregir el job.

## Revisión condicional de tendencias por prioridad

`red_review_request:true`, `task:review_red` es una investigación de novedades, NO una orden de reescribir. El snapshot `review_source` contiene ID, revisión, explicación, fecha y fingerprint originales. El planificador selecciona explicaciones que siguen en Top 30 fresco, con prioridad rojas (>24h), después amarillas (12–24h inclusive) y después verdes (<12h). En cada color atiende primero las menos revisadas y las que llevan más tiempo sin comprobar. Crea como máximo DOS comprobaciones automáticas en cualquier ventana móvil de15 minutos y mantiene como máximo DOS pendientes/en curso; terminar una no rellena el cupo antes de15min. Cada origen admite como máximo una comprobación por hora. Las investigaciones nuevas y revisiones manuales tienen prioridad y no están sujetas a este cupo automático. No revisar por debajo de Top 30 ni interpretar un color como prueba de un hecho nuevo. Los nombres técnicos red_review_request, task:review_red y red_review_* se conservan por compatibilidad y se aplican a los tres colores.

Contrastar información posterior con el hecho que explicaba la tendencia. Una subida de puesto, sinónimos, otro hashtag, artículos que repiten lo conocido o seguir hablando del mismo asunto no bastan. Hace falta un cambio material que cambie la explicación actual: resolución, resultado, confirmación, anuncio o desarrollo concreto. No renovar `explained_at` para aparentar frescura.

Guardar SOLO `trends/maintenance-outbox/<job_id>.json` con uno de estos resultados:

```json
{"job_id":"ID_REVISION","outcome":"unchanged","reason":"Se mantiene el mismo motivo sin novedades sustanciales","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

```json
{"job_id":"ID_REVISION","outcome":"updated","reason":"Qué cambia respecto a la explicación anterior","new_facts":"Hechos nuevos verificados","distinct_episode":false,"explanation":"TT#3 Nombre sigue siendo tendencia por ...\n#Etiqueta1 #Etiqueta2","closer_text":"","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

```json
{"job_id":"ID_REVISION","outcome":"unverified","reason":"Motivo concreto por el que no se ha podido verificar","verification_sources":[]}
```

En continuidad usar «sigue siendo tendencia por…» o «siguen siendo tendencia por…». Si se comprueba un episodio genuinamente distinto (p. ej., otro partido días después), marcar `distinct_episode:true`, explicar la diferencia en `reason/new_facts`, y usar el comienzo ordinario «es tendencia por…». No deducir un episodio nuevo solo de que hayan pasado 48h.

El aplicador conserva texto y fecha con `unchanged/unverified`, guardando `red_review_checked_at`, resultado y motivo aparte. Con `updated`, crea una ficha con ID nuevo en Listas y la somete a agrupación antes de su imagen. Una ficha anterior no publicada puede quedar marcada cubierta; una publicada conserva su estado e historial terminal. No incrementar contadores ni dar por publicada una actualización. Ante `review_error`, corregir el mismo resultado. Releer el job `review_completed` y los datos persistidos; no procesar como ready ordinario ni borrar el origen.

## Cierre de la pasada

Releer la cola y los resultados aplicados. Verificar que cada revisión ordinaria cerrada coincide entre request y ficha, y que cada mantenimiento tratado tiene su resultado aplicado. Distinguir los pendientes de verificación de los pendientes de transporte. Registrar incidencias precisas con ID/revisión y primer eslabón ausente; no afirmar que una solicitud, un ACK o un workflow verde equivale a texto terminado, imagen entregada o publicación en X.
