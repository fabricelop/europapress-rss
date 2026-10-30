# TTendencias · contrato editorial vigente

Este contrato gobierna la misma pasada editorial iniciada por «Ejecuta TTendencias», el iPhone, Windows o su programación. La fuente de datos es `fabricelop/europapress-rss/main`; los triggers y jobs visuales usan `control/ttendencias-run-trigger`. Las instrucciones del usuario prevalecen. No publicar en X: el editor conserva siempre la decisión de publicación.

## Resultado y límites

El cierre editorial es texto verificado persistido en `trends/requests.json` y `trends/telegram-manual-explained.json`, con la revisión exacta retirada de `trends/editorial-queue.json`. READY/explained no espera fotos, IA ni Telegram. El panel editorial es TTActualidad nativa; Telegram editorial está retirado. TTImages es un transporte independiente desde el PC. No activar ImageGen, llamar al bot TTImages ni generar `trends/image-outbox/**` en esta pasada. Preservar FabCalendar, SeLoRecordamos, URGENTE, credenciales, sesiones y el Chrome de otros procesos.

Todas las pendientes del Top 30 (puestos 1–30) se investigan automáticamente. Las 31+ no entran como fichas del Top30 por ranking. El Radar puede encargar hasta dos borradores anticipados según el contrato siguiente. Las solicitudes manuales y pistas ya aceptadas se conservan aunque cambien de puesto o salgan del ranking. La edad por sí sola no autoriza otra publicación ni un nuevo episodio: las explicaciones requieren la revisión condicional de novedades descrita aquí.

## Inicio, orden y barrera de estado

1. Leer `trends/editorial-config.json`, `recent.json`, `requests.json`, `editorial-queue.json`, `telegram-manual-explained.json`, `mobile-decisions.json` y los últimos resultados de mantenimiento. La cola compacta vigente es autoritativa, incluso cuando está vacía. No resucitar trabajo desde resúmenes antiguos.
2. Correlacionar siempre proyecto, ID, revisión y fecha. Reconciliar textos ya persistidos con la revisión exacta; nunca por nombre solamente. Atender `rewrite_pending:true` si sigue vigente y no tiene una revisión posterior ni decisión terminal.
3. Procesar primero todas las nuevas investigaciones y reelaboraciones manuales `preparing/update`, de antiguas a recientes. Después, agrupaciones `task:group_listas`; después borradores Radar `task:anticipate`; después revisiones de novedades `task:review_red`. Las problemáticas ordinarias se reintentan al final si siguen en el Top 30. Releer la cola antes de cerrar: un trabajo nuevo puede haber llegado durante la pasada.
4. Justo antes de investigar, persistir o aplicar resultados, releer main y comprobar ID+revisión. Si el editor ha quitado, publicado, reelaborado o sustituido una revisión, respetar su estado. No borrar ni reabrir terminales; no sustituir textos más nuevos con snapshots de inicio. Una solicitud especial se completa mediante SU outbox, nunca convirtiéndola en una tendencia ficticia explicada.
5. El workflow `ttactualidad-group-listas.yml` mantiene las solicitudes especiales y se revisa cada cinco minutos, con posible retraso de Actions. Usa el mismo `trends/request_pc_editorial.py --trigger` y el mismo consumidor Windows. El trigger no demuestra ejecución: confirmar RUNNING real y resultado aplicado.

## Telemetría y ejecución real

«Ejecuta TTendencias» requiere ejecutar el trabajo en la conversación activa, no solo escribir un trigger. Delegar al PC únicamente si existe consumidor comprobado y ACK RUNNING. El PR #7 se usa para control, telemetría y transporte editorial; mantener el comentario canónico `TTENDENCIAS_RUNTRACE_V1` con `canonical:true` (verificar su ID actual, no crear uno por pasada).

Al iniciar actualizar el mismo RUNTRACE y `trends/editorial-runtime.json` con run_id, RUNNING, started_at, updated_at, current y total reales. Emitir fases reales `preparing`, `investigating`, `drafting`, `remate_selection`, `persisting`, `verifying`, `closing`, título, trend_id y mensaje concreto. En mantenimiento indicar «Revisando novedades», «Sin novedades», «Verificando acontecimiento común» o el motivo de bloqueo. No usar fases de generación de imágenes en el editor textual.

Al terminar persistir DONE/DONE_WITH_INCIDENTS o ERROR conforme al resultado real, finished_at y resumen de IDs/revisiones cerrados, revisiones sin novedades, actualizaciones, grupos y pendientes. Guardar `last_run` durable incluso con 0/0. No declarar éxito si falta persistir texto o aplicar un resultado tratado. Una cola vacía no prueba salud de imágenes. No solicitar estrellas ni usar ratings para escoger remates.

## Investigación ordinaria

Investigar por qué el término es tendencia AHORA. Contrastar fuentes actuales y fechas; distinguir el acontecimiento del que habla la gente del nombre de una persona, equipo o etiqueta. No usar capturas simultáneas, `batch_id`, palabras compartidas o partido político como prueba de un mismo acontecimiento. Las pistas `user_pistas` son hipótesis sin verificar; conservarlas con `investigation_history` y buscar corroboración independiente. No convertir una pista o rumor en hecho.

Tras dos búsquedas independientes, si no se demuestra el detonante preciso pero SÍ está comprobado que el término figura en una captura fiable y actual del Top 30, redactar de todos modos una **explicación con causa no confirmada** para Listas. La falta de prueba causal NO bloquea por sí sola el cierre editorial. Describir únicamente el ranking observado, los hechos de contexto acreditados y el límite de certeza: «coincide con…», «podría estar relacionado, pero no está confirmado» (esta última fórmula solo con indicios públicos verificables de relación) o «no se ha podido confirmar qué ha impulsado la etiqueta». Nunca atribuir el movimiento a un partido, grupo o campaña solo por una pista del editor, correlación temporal o parecido textual; el matiz «parece» no convierte una acusación sin pruebas en publicable. Guardar las búsquedas, fuentes y la incertidumbre en `investigation_history`/`verification_sources`.

Si ni siquiera puede verificarse una aparición actual fiable, falta el contexto mínimo o hay riesgo de difundir acusaciones/rumores sin fundamento, conservar `problematic` con motivo preciso y continuar. Las problemáticas activas del Top 30 pueden reintentarse; no reabrir fichas `inactive`/terminales ni reconstruir un puesto histórico como si fuera actual. Una explicación prudente finalizada pasa a `status:explained` como las demás, sin publicación automática.

Tremending conserva su prefijo `TT 🗯️`, origen trazable y circuito de tuit/foto real. No sustituir esa captura por una imagen inventada ni confundir este flujo con tendencias ordinarias.

## Criterio de causalidad editorial (prioritario)

La incertidumbre explícita es EXCEPCIONAL, no una coletilla automática. No exigir una prueba imposible de causalidad algorítmica en X. Si fuentes actuales y hechos contrastados permiten identificar razonablemente el motivo predominante, redactar directamente «es tendencia por/porque…», sin añadir «no está confirmado que ese hecho explique el impulso» ni similares. Si hay indicios suficientes pero no certeza plena, modular con «en medio de», «tras» o «en relación con» sin afirmar una causalidad no acreditada. Reservar «no se ha podido confirmar el motivo» para ambigüedad real: varias causas incompatibles sin predominante, identidad desconocida, falta de indicios actuales o atribución potencialmente perjudicial. El simple hecho de no disponer de métricas internas de X NO constituye duda sustancial. Mantener la distinción entre hechos comprobados e hipótesis, sin inventar detonantes. Esta regla prevalece sobre ejemplos anteriores de causa no confirmada y se aplica también a revisión manual y mantenimiento.

Cuando una ficha ya explicada de Listas contenga una coletilla defensiva innecesaria, investigar de nuevo la actualidad y fuentes antes de corregirla. Cambiar solo fichas vigentes y justificadas, mediante revisión ID/revisión JIT y persistencia sincronizada en ambos registros; no cambiar fechas por mera edición estilística, no alterar publicadas/terminales ni regenerar imágenes por defecto. Si hay cambio material de explicación, usar el circuito de actualización existente y sus comprobaciones.

## Redacción y remate

Mantener el estilo habitual del usuario. Para una primera explicación ordinaria:

```text
TT#N <nombre literal> es tendencia porque <hecho actual verificado>.
#EtiquetaEspecifica1 #EtiquetaEspecifica2
🌶️ <remate único>
```

Cuando la causa no esté confirmada, evitar «es tendencia porque»: usar la misma cabecera y longitud, pero distinguir explícitamente contexto comprobado de hipótesis. Por ejemplo:

```text
TT#N <nombre literal> aparece entre las tendencias mientras <hecho contextual contrastado>. No está confirmado que ese hecho haya impulsado la etiqueta.
#EtiquetaEspecifica1 #EtiquetaEspecifica2
```

Si solo consta el ranking, informar «se desconoce el motivo concreto» sin inventar un contexto. Evitar remates que insinúen como cierta una causa dudosa; `closer_text:""` es válido en estos casos.

Se admiten tres hashtags si aportan precisión y caben. No repetir un hashtag ya usado como nombre literal de cabecera. Evitar etiquetas genéricas, propaganda, especulación y hechos añadidos por el chiste. El tuit COMPLETO, con cabecera, hashtags, saltos y remate, debe tener menos de 280 caracteres ponderados X (URLs: 23). `closer_text` contiene únicamente la última línea `🌶️ ...`, o vacío cuando la omisión sea apropiada; no incluir hashtags en ese campo. No duplicar remate ni cabecera. El campo `explanation` es el tuit completo copiable.

Elegir un solo remate breve, concreto, original y ligado a hechos documentados, sin puntuaciones ni estrellas. Evitar repetir fórmulas recientes: consultar las últimas explicaciones y remates cuando sea necesario. **NORMA VISUAL PRIORITARIA 16/10/2026:** el emoji 🌶️ es únicamente un marcador tipográfico. Prohibido dibujar guindillas, chiles, pimientos picantes, su icono, silueta, logotipo o mascota; representar la idea del remate, nunca el emoji. Política: el remate seguro es obligatorio para completar la revisión, debe ser imparcial y sobre circunstancias verificadas; no convertirlo en consigna. No usar humor sobre víctimas, tragedias o sufrimiento. En asuntos sensibles y en los supuestos no políticos permitidos, cuando no corresponda o no exista uno adecuado, cerrar el texto factual con hashtags y `closer_text:""`; no bloquear indefinidamente un hecho verificado solo por el chiste. Mantener las reglas editoriales de sensibilidad del usuario.

## Persistencia ordinaria y Listas

Para cada tendencia redactar y guardar su propia explicación. La comparación semántica posterior crea las conjuntas sin reescribir originales. No usar el antiguo mecanismo que copia una explicación canónica a todas las requests o marca `grouped` y oculta miembros.

Persistir atómicamente en main tanto una explicación de causa confirmada como una explicación prudente de causa no confirmada con ficha `status:explained` en `telegram-manual-explained.json` y su request, con ID, revisión, explanation, closer_text y explained_at idénticos. Conservar fuentes verificadas y `editorial_grouping_state:"pending"`. El mismo contrato se aplica a una nueva revisión manual. Retirar solo el mismo ID/revisión de la cola después de releer ambos registros. Un texto en requests sin ficha no está terminado. Si falla una escritura, releer SHA y reparar la misma revisión sin redactar otra ni resucitar estados cerrados.

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

## Preparación anticipada del Radar

`anticipation_request:true`, `task:anticipate` identifica un borrador de investigación de una señal fuera del Top30. Su nombre de job es «Radar · …» y rank0 es interno: no es un puesto real de X. El término literal está en `anticipated_name` y las observaciones en `anticipation_signal`. No convertirlo en explained/ready, no añadirlo a Listas, no usar el outbox ordinario, no generar foto ni IA y no publicar.

El selector usa exclusivamente las fuentes públicas ya existentes, sin API de pago ni servicios nuevos. Admite como máximo dos borradores pendientes o preparados y dos encargos nuevos por ventana móvil de15min, siempre detrás de investigaciones nuevas/manuales del Top30. Exige dos observaciones, subida de al menos ocho puestos o aumento de corroboración, dos rankings no casi idénticos, al menos uno fechado y fresco, señal detectada hace45min o menos y captura vigente. Un término del Top30, ya investigado o con decisión previa no se abre de nuevo por este mecanismo.

Investigar el detonante con fuentes actuales y redactar el cuerpo del tuit habitual, hashtags y remate si procede, **sin prefijo TT#N ni puesto inventado**. El cuerpo debe permitir añadir después `TT#30 ` sin alcanzar280 caracteres ponderados. Guardar únicamente `trends/anticipation-outbox/<job_id>.json`:

```json
{"job_id":"radar-prepare-ID","revision":0,"outcome":"prepared","reason":"Detonante comprobado","explanation_body":"Nombre es tendencia por el hecho verificado.\n#Etiqueta1 #Etiqueta2","closer_text":"","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

Si no se verifica, guardar `outcome:"unverified"`, motivo preciso y la misma identidad. No forzar una explicación ni pedir estrellas. El aplicador guarda `anticipation_prepared` o `anticipation_unverified` en requests y retira solo el job cerrado de la cola. Ante `anticipation_error`, corregir el mismo resultado; un job expirado/sustituido no se revive.

El borrador caduca una hora después de solicitarse. Cuando el término entra en el Top30, el selector normal registra la petición real; si es automática y existe borrador fresco, añade `anticipation_draft` y `anticipation_origin_id` a esa petición, sin crear otra ni modificar una petición manual/terminal. **Revalidar fecha, detonante y fuentes**, usar el puesto real y el estilo habitual antes de cerrar texto. Una preparación pendiente al entrar se sustituye por el trabajo Top30, evitando dos investigaciones paralelas. Después del cierre normal siguen agrupación e imágenes habituales.

`trends/anticipation-metrics.json` distingue adelanto de detección y adelanto del borrador ya verificado respecto a la primera entrada observada en Top30. No presentar un borrador caducado como preparación útil ni confundir estas métricas con la hora oficial del ranking o una publicación. El límite de gasto externo es0€; no activar API X, proveedores de pago ni planes nuevos.

## Revisión condicional de tendencias por prioridad

`red_review_request:true`, `task:review_red` es una investigación de novedades, NO una orden de reescribir. El snapshot `review_source` contiene ID, revisión, explicación, fecha y fingerprint originales. El planificador selecciona explicaciones que siguen en Top 30 fresco, con prioridad rojas (>24h), después amarillas (12–24h inclusive) y después verdes (<12h). En cada color atiende primero las menos revisadas y las que llevan más tiempo sin comprobar. Crea como máximo DOS comprobaciones automáticas en cualquier ventana móvil de15 minutos y mantiene como máximo DOS pendientes/en curso; terminar una no rellena el cupo antes de15min. Cada origen admite como máximo una comprobación por hora. Las investigaciones nuevas y revisiones manuales tienen prioridad y no están sujetas a este cupo automático. No revisar por debajo de Top 30 ni interpretar un color como prueba de un hecho nuevo. Los nombres técnicos red_review_request, task:review_red y red_review_* se conservan por compatibilidad y se aplican a los tres colores.

Contrastar información posterior con el hecho que explicaba la tendencia. Si el texto anterior declaraba la causa no confirmada, la aparición de evidencia posterior que la confirme o descarte y cambie sustancialmente la explicación es una novedad material; una mera hipótesis repetida no lo es. Una subida de puesto, sinónimos, otro hashtag, artículos que repiten lo conocido o seguir hablando del mismo asunto no bastan. Hace falta un cambio material que cambie la explicación actual: resolución, resultado, confirmación, anuncio o desarrollo concreto. No renovar `explained_at` para aparentar frescura.

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
