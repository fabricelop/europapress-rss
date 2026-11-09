# TTendencias · contrato editorial vigente

Este contrato gobierna la misma pasada editorial iniciada por «Ejecuta TTendencias», el iPhone, Windows o su programación. La fuente de datos es `fabricelop/europapress-rss/main`; los triggers y jobs visuales usan `control/ttendencias-run-trigger`. Las instrucciones del usuario prevalecen. No publicar en X: el editor conserva siempre la decisión de publicación.

## Resultado y límites

El cierre editorial es texto verificado persistido en `trends/requests.json` y `trends/telegram-manual-explained.json`, con la revisión exacta retirada de `trends/editorial-queue.json`. READY/explained no espera fotos, IA ni Telegram. El panel editorial es TTActualidad nativa; Telegram editorial está retirado. TTImages es un transporte independiente desde el PC. No activar ImageGen, llamar al bot TTImages ni generar `trends/image-outbox/**` en esta pasada. Preservar FabCalendar, SeLoRecordamos, URGENTE, credenciales, sesiones y el Chrome de otros procesos.

Todas las pendientes del Top 30 (puestos 1–30) que sean primeras apariciones sin explicación o reentradas rojas verificadas se investigan automáticamente. Las 31+ no entran como fichas del Top30 por ranking. El Radar puede encargar hasta dos borradores anticipados según el contrato siguiente. Las solicitudes manuales y pistas ya aceptadas se conservan aunque cambien de puesto o salgan del ranking. La edad por sí sola no autoriza otra publicación ni un nuevo episodio: las explicaciones requieren la revisión condicional de novedades descrita aquí.

## Novedades con nombre repetido: investigación individual, nunca duplicado

Un nombre del Top 30 **no es un ID de noticia ni prueba de un acontecimiento nuevo**. Aplicar esta norma por edad de la **última explicación verificada** y con señales reales de entrada al Top 30, nunca por el simple puesto:

- **Primera entrada sin explicación histórica:** crear investigación ordinaria en `preparing`.
- **Regreso con explicación de menos de 24 h (verde: menos de 12 h; amarilla: 12–24 h inclusive):** conservar texto, ID, revisión, imagen y decisiones; **no** reevaluar automáticamente ni crear una ficha nueva.
- **Regreso al Top 30 después de más de 24 h desde la última explicación (roja temporal):** si `entered_top30_at` acredita una entrada posterior a `explained_at + 24 h`, crear **una única investigación** `status:preparing`, `new_episode_review:true`, `distinct_event_required:true` con un **ID independiente de investigación** y `radar_episode_token` estable `reentry:<fecha_entrada>`. Esto se aplica incluso si la ficha anterior fue publicada o eliminada, sin reabrir ni modificar su decisión. El objetivo es verificar **por qué ha vuelto**. Una subida/bajada de rango, seguir presente o que hayan pasado 24 h sin una salida y regreso observados **no** dispara esta vía.
- **Mismo regreso ya investigado:** `review_completed/no_distinct_event` y cualquier otra solicitud con el mismo `radar_episode_token` impiden repetir esa investigación. Solo una entrada realmente posterior puede crear otra.
- **Regreso sin fecha fiable de entrada o con explicación anterior sin fecha:** no inventar episodio; conservar estado y admitir investigación manual.

**Investigación antes que otra publicación:** la reentrada justifica investigar, **no autoriza publicar** automáticamente. Comparar hechos y fechas con el episodio anterior. Si hay acontecimiento verdaderamente distinto, posterior, material y respaldado por fuentes, aplicar `material_event_key`, `material_event_at`, `material_change:true` y `significance_reason` según el contrato inferior para crear una nueva ficha independiente en Listas. Si se trata de la misma razón, cerrar la investigación como `review_completed/no_distinct_event`, conservar la ficha, imagen, ID y decisiones antiguos, no producir nueva imagen ni enviar otra publicación. Nunca presentar una simple continuación como acontecimiento nuevo. La investigación manual expresamente solicitada continúa disponible a cualquier edad.

**Mantenimiento de rojas que PERMANECEN en Top 30:** `red_review_request` mantiene su circuito independiente de revisión automática por antigüedad estricta (>24 h) con radar fresco y límites de frecuencia; verdes/amarillas no entran. La reentrada nueva después de más de 24 h utiliza el circuito `auto_queue_new.py` descrito arriba y **no** convierte el regreso en un tuit duplicado. Las insignias rojas por importancia editorial no equivalen a antigüedad. Preservar todos los procesos existentes de edición, fotos, Buffer, Site y control manual.

**Agrupaciones de TTendencias retiradas completamente del flujo activo:** una tendencia = una solicitud = una explicación independiente. Ni siquiera generar `group_id`, `explanation_group_id`, `group_leader_id`, `grouped_member_revisions`, `group_title`, `grouped_into` o `status:grouped` para fichas nuevas, aunque compartan un partido, programa o nombre. Tampoco emitir un "grupo" de un único elemento. Conservar exclusivamente en el archivo histórico las agrupaciones anteriores ya cerradas; no copiarlas a revisiones actuales ni hacer que Baena/Adeyemi hereden explicaciones de un líder antiguo.

## Inicio, orden y barrera de estado

1. Leer `trends/editorial-config.json`, `recent.json`, `requests.json`, `editorial-queue.json`, `telegram-manual-explained.json`, `mobile-decisions.json` y los últimos resultados de mantenimiento. La cola compacta vigente es autoritativa, incluso cuando está vacía. No resucitar trabajo desde resúmenes antiguos.
2. Correlacionar siempre proyecto, ID, revisión y fecha. Reconciliar textos ya persistidos con la revisión exacta; nunca por nombre solamente. Atender `rewrite_pending:true` si sigue vigente y no tiene una revisión posterior ni decisión terminal.
3. Procesar primero todas las nuevas investigaciones y reelaboraciones manuales `preparing/update`, de antiguas a recientes. Después borradores Radar `task:anticipate`; después revisiones de novedades `task:review_red`. Las problemáticas ordinarias se reintentan al final si siguen en el Top 30. Releer la cola antes de cerrar: un trabajo nuevo puede haber llegado durante la pasada.
4. Justo antes de investigar, persistir o aplicar resultados, releer main y comprobar ID+revisión. Si el editor ha quitado, publicado, reelaborado o sustituido una revisión, respetar su estado. No borrar ni reabrir terminales; no sustituir textos más nuevos con snapshots de inicio. Una solicitud especial se completa mediante SU outbox, nunca convirtiéndola en una tendencia ficticia explicada.
5. El workflow `ttactualidad-group-listas.yml` mantiene las solicitudes especiales y se revisa cada cinco minutos, con posible retraso de Actions. Usa el mismo `trends/request_pc_editorial.py --trigger` y el mismo consumidor Windows. El trigger no demuestra ejecución: confirmar RUNNING real y resultado aplicado.

## Telemetría y ejecución real

«Ejecuta TTendencias» requiere ejecutar el trabajo en la conversación activa, no solo escribir un trigger. Delegar al PC únicamente si existe consumidor comprobado y ACK RUNNING. El PR #7 se usa para control, telemetría y transporte editorial; mantener el comentario canónico `TTENDENCIAS_RUNTRACE_V1` con `canonical:true` (verificar su ID actual, no crear uno por pasada).

Al iniciar actualizar el mismo RUNTRACE y `trends/editorial-runtime.json` con run_id, RUNNING, started_at, updated_at, current y total reales. Emitir fases reales `preparing`, `investigating`, `drafting`, `remate_selection`, `persisting`, `verifying`, `closing`, título, trend_id y mensaje concreto. En mantenimiento indicar «Revisando novedades», «Sin novedades», «Verificando acontecimiento común» o el motivo de bloqueo. No usar fases de generación de imágenes en el editor textual.

Al terminar persistir DONE/DONE_WITH_INCIDENTS o ERROR conforme al resultado real, finished_at y resumen de IDs/revisiones cerrados, revisiones sin novedades, actualizaciones, grupos y pendientes. Guardar `last_run` durable incluso con 0/0. No declarar éxito si falta persistir texto o aplicar un resultado tratado. Una cola vacía no prueba salud de imágenes. No solicitar estrellas ni usar ratings para escoger remates.

## Investigación ordinaria

Investigar por qué el término es tendencia AHORA. Contrastar fuentes actuales y fechas; distinguir el acontecimiento del que habla la gente del nombre de una persona, equipo o etiqueta. No usar capturas simultáneas, `batch_id`, palabras compartidas o partido político como prueba de un mismo acontecimiento. Las pistas `user_pistas` son hipótesis sin verificar; conservarlas con `investigation_history` y buscar corroboración independiente. No convertir una pista o rumor en hecho.

Solo para la **primera investigación ordinaria**, tras dos búsquedas independientes, si no se demuestra el detonante preciso pero SÍ está comprobado que el término figura en una captura fiable y actual del Top 30, redactar de todos modos una **explicación con causa no confirmada** para Listas. **Esta excepción no vale para `new_episode_review:true`: una segunda ficha requiere un acontecimiento material distinto verificado.** La falta de prueba causal NO bloquea por sí sola el cierre editorial. Describir únicamente el ranking observado, los hechos de contexto acreditados y el límite de certeza: «coincide con…», «podría estar relacionado, pero no está confirmado» (esta última fórmula solo con indicios públicos verificables de relación) o «no se ha podido confirmar qué ha impulsado la etiqueta». Nunca atribuir el movimiento a un partido, grupo o campaña solo por una pista del editor, correlación temporal o parecido textual; el matiz «parece» no convierte una acusación sin pruebas en publicable. Guardar las búsquedas, fuentes y la incertidumbre en `investigation_history`/`verification_sources`.

Si ni siquiera puede verificarse una aparición actual fiable, falta el contexto mínimo o hay riesgo de difundir acusaciones/rumores sin fundamento, conservar `problematic` con motivo preciso y continuar. Las problemáticas activas del Top 30 pueden reintentarse; no reabrir IDs `inactive`/terminales ni reconstruir un puesto histórico como si fuera actual; las reentradas autorizadas crean **otra investigación independiente**, sin mutar las fichas terminales. Una explicación prudente finalizada pasa a `status:explained` como las demás, sin publicación automática.

Tremending conserva su prefijo `TT 🗯️`, origen trazable y circuito de tuit/foto real. No sustituir esa captura por una imagen inventada ni confundir este flujo con tendencias ordinarias.

## Criterio de causalidad editorial (prioritario)

La incertidumbre explícita es EXCEPCIONAL, no una coletilla automática. No exigir una prueba imposible de causalidad algorítmica en X. Si fuentes actuales y hechos contrastados permiten identificar razonablemente el motivo predominante, redactar directamente «es tendencia por/porque…», sin añadir «no está confirmado que ese hecho explique el impulso» ni similares. Si hay indicios suficientes pero no certeza plena, modular con «en medio de», «tras» o «en relación con» sin afirmar una causalidad no acreditada. Reservar «no se ha podido confirmar el motivo» para ambigüedad real: varias causas incompatibles sin predominante, identidad desconocida, falta de indicios actuales o atribución potencialmente perjudicial. El simple hecho de no disponer de métricas internas de X NO constituye duda sustancial. Mantener la distinción entre hechos comprobados e hipótesis, sin inventar detonantes. Esta regla prevalece sobre ejemplos anteriores de causa no confirmada y se aplica también a revisión manual y mantenimiento.

Cuando una ficha ya explicada de Listas contenga una coletilla defensiva innecesaria, investigar de nuevo la actualidad y fuentes antes de corregirla. Cambiar solo fichas vigentes y justificadas, mediante revisión ID/revisión JIT y persistencia sincronizada en ambos registros; no cambiar fechas por mera edición estilística, no alterar publicadas/terminales ni regenerar imágenes por defecto. Si hay cambio material de explicación, usar el circuito de actualización existente y sus comprobaciones.

## Regla editorial prioritaria 07/11/2026 — sin antirremates

**Prohibido escribir frases como «Aquí no hay chiste», «No hay chiste», «No es momento de bromas», «El humor se aparta» o equivalentes.** No justificar la ausencia de humor ni usar un falso remate que describa la falta de gracia. En muertes, heridos, tragedias, violencia u otras noticias sensibles, si no existe un remate realmente pertinente y respetuoso, **terminar con los hechos contrastados** (por ejemplo, «Hay víctimas y una investigación abierta» solo si consta). Mantener la explicación y los hashtags sin `🌶️`, guardar `closer_text:""` y continuar el cierre editorial; el humor nunca debe ser condición para publicar hechos verificados. No reabrir ni republicar una ficha que ya esté cerrada.

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

Para cada tendencia redactar y guardar su propia explicación. No crear comparaciones de agrupación ni fichas conjuntas; las relaciones de lectura no alteran los textos. No usar el antiguo mecanismo que copia una explicación canónica a todas las requests o marca `grouped` y oculta miembros.

Persistir atómicamente en main tanto una explicación de causa confirmada como una explicación prudente de causa no confirmada con ficha `status:explained` en `telegram-manual-explained.json` y su request, con ID, revisión, explanation, closer_text y explained_at idénticos. Conservar fuentes verificadas y los metadatos históricos; ninguna explicación individual espera una agrupación. El mismo contrato se aplica a una nueva revisión manual. Retirar solo el mismo ID/revisión de la cola después de releer ambos registros. Un texto en requests sin ficha no está terminado. Si falla una escritura, releer SHA y reparar la misma revisión sin redactar otra ni resucitar estados cerrados.

La ruta de transporte existente por comentarios `TTENDENCIAS_CHAT_OUTBOX_V1` en PR #7 y los reconciliadores siguen disponibles. En el modo heredado de `trends/editorial-outbox/<id>-r<revision>.json`, guardar texto/metadatos (`status:ready`, `prepared_item`) y comprobar que el aplicador `ttendencias-editorial-apply.yml` lo ha convertido en la ficha real. No incluir IA inline ni asumir que crear el outbox cierra el trabajo.

El botón manual «Enviar a TTiTTulares» sí existe: crea una investigación independiente con origen ID/revisión y conserva la tendencia. Esta pasada NO envía automáticamente tendencias a noticias; tampoco prohíbe la acción explícita del usuario.

## Pistas del editor y retirada de agrupación (03/11/2026)

Una pista nueva del usuario sobre una tendencia ya explicada (incluso causa desconocida) abre investigación/reelaboración de ESA ficha existente con su ID y revisión, en vez de descartarla por explained. Comprobar la pista independientemente; si acredita una explicación mejor, actualizar ambos registros mediante el circuito vigente, sin resucitar terminales ni pisar revisiones posteriores.

La agrupación de Tendencias está retirada por decisión del editor, tanto manual como automática. La prohibición incluye metadatos de grupos con líder igual al propio ID y la reconciliación automática de seguidores; una ficha nueva debe ser completamente individual. No solicitar, ejecutar ni producir resultados `listas_grouping_request:true` / `task:group_listas`; no crear fichas conjuntas, no cubrir originales por una coincidencia temática y no escribir nuevos outboxes de agrupación. Los jobs especiales antiguos se cierran por el mantenedor como `grouping_retired`, conservando snapshots e historial; no tratarlos como investigaciones ordinarias ni aplicar sus resultados tardíos. Los comandos de clientes antiguos reciben `TREND_GROUPING_RETIRED`.

Cada tendencia conserva su ficha independiente. Las relaciones visuales noticia↔tendencia no agrupan textos ni publicaciones y no autorizan modificar originales. Conservar íntegros los grupos/coberturas históricos, fuentes, imágenes, fechas, revisiones y terminales; no borrar o restaurar originales por deducción. Las imágenes individuales no requieren clearance de agrupación; las fichas históricas cubiertas y los borradores anticipados mantienen sus barreras. No cancelar imágenes ya lanzadas ni aprobarlas desde esta pasada.

## Preparación anticipada del Radar

`anticipation_request:true`, `task:anticipate` identifica un borrador de investigación de una señal fuera del Top30. Su nombre de job es «Radar · …» y rank0 es interno: no es un puesto real de X. El término literal está en `anticipated_name` y las observaciones en `anticipation_signal`. No convertirlo en explained/ready, no añadirlo a Listas, no usar el outbox ordinario, no generar foto ni IA y no publicar.

El selector usa exclusivamente las fuentes públicas ya existentes, sin API de pago ni servicios nuevos. Admite como máximo dos borradores pendientes o preparados y dos encargos nuevos por ventana móvil de15min, siempre detrás de investigaciones nuevas/manuales del Top30. Exige dos observaciones, subida de al menos ocho puestos o aumento de corroboración, dos rankings no casi idénticos, al menos uno fechado y fresco, señal detectada hace45min o menos y captura vigente. Un término del Top30, ya investigado o con decisión previa no se abre de nuevo por este mecanismo.

Investigar el detonante con fuentes actuales y redactar el cuerpo del tuit habitual, hashtags y remate si procede, **sin prefijo TT#N ni puesto inventado**. El cuerpo debe permitir añadir después `TT#30 ` sin alcanzar280 caracteres ponderados. Guardar únicamente `trends/anticipation-outbox/<job_id>.json`:

```json
{"job_id":"radar-prepare-ID","revision":0,"outcome":"prepared","reason":"Detonante comprobado","explanation_body":"Nombre es tendencia por el hecho verificado.\n#Etiqueta1 #Etiqueta2","closer_text":"","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

Si no se verifica, guardar `outcome:"unverified"`, motivo preciso y la misma identidad. No forzar una explicación ni pedir estrellas. El aplicador guarda `anticipation_prepared` o `anticipation_unverified` en requests y retira solo el job cerrado de la cola. Ante `anticipation_error`, corregir el mismo resultado; un job expirado/sustituido no se revive.

El borrador caduca una hora después de solicitarse. Cuando el término entra en el Top30, el selector normal registra la petición real; si es automática y existe borrador fresco, añade `anticipation_draft` y `anticipation_origin_id` a esa petición, sin crear otra ni modificar una petición manual/terminal. **Revalidar fecha, detonante y fuentes**, usar el puesto real y el estilo habitual antes de cerrar texto. Una preparación pendiente al entrar se sustituye por el trabajo Top30, evitando dos investigaciones paralelas. Después del cierre normal sigue el ciclo habitual de imágenes, sin agrupación.

`trends/anticipation-metrics.json` distingue adelanto de detección y adelanto del borrador ya verificado respecto a la primera entrada observada en Top30. No presentar un borrador caducado como preparación útil ni confundir estas métricas con la hora oficial del ranking o una publicación. El límite de gasto externo es0€; no activar API X, proveedores de pago ni planes nuevos.

## Revisión condicional de tendencias por prioridad

`red_review_request:true`, `task:review_red` es una investigación de novedades, NO una orden de reescribir. El snapshot `review_source` contiene ID, revisión, explicación, fecha y fingerprint originales. El planificador selecciona exclusivamente explicaciones rojas por antigüedad (>24h) dentro de un Top 30 fresco; **nunca** selecciona automáticamente amarillas (12–24h inclusive) ni verdes (<12h). Entre las rojas atiende primero las menos revisadas y las que llevan más tiempo sin comprobar. Crea como máximo DOS comprobaciones automáticas en cualquier ventana móvil de15 minutos y mantiene como máximo DOS pendientes/en curso; terminar una no rellena el cupo antes de15min. Cada origen admite como máximo una comprobación por hora. Las investigaciones nuevas y revisiones manuales tienen prioridad y no están sujetas a este cupo automático. No revisar por debajo de Top 30 ni interpretar un color como prueba de un hecho nuevo. Los nombres técnicos red_review_request, task:review_red y red_review_* se conservan por compatibilidad; el planificador automático se limita a las rojas por antigüedad.

Contrastar información posterior con el hecho que explicaba la tendencia. Si el texto anterior declaraba la causa no confirmada, la aparición de evidencia posterior que la confirme o descarte y cambie sustancialmente la explicación es una novedad material; una mera hipótesis repetida no lo es. Una subida de puesto, sinónimos, otro hashtag, artículos que repiten lo conocido o seguir hablando del mismo asunto no bastan. Hace falta un cambio material que cambie la explicación actual: resolución, resultado, confirmación, anuncio o desarrollo concreto. No renovar `explained_at` para aparentar frescura.

Guardar SOLO `trends/maintenance-outbox/<job_id>.json` con uno de estos resultados:

```json
{"job_id":"ID_REVISION","outcome":"unchanged","reason":"Se mantiene el mismo motivo sin novedades sustanciales","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

```json
{"job_id":"ID_REVISION","outcome":"updated","reason":"Qué cambia respecto a la explicación anterior","new_facts":"Hechos nuevos verificados","distinct_episode":false,"material_change":false,"significance_reason":"","explanation":"TT#3 Nombre sigue siendo tendencia por ...\n#Etiqueta1 #Etiqueta2","closer_text":"","verification_sources":[{"url":"https://FUENTE_REAL_VERIFICADA"}]}
```

```json
{"job_id":"ID_REVISION","outcome":"unverified","reason":"Motivo concreto por el que no se ha podido verificar","verification_sources":[]}
```

En continuidad usar «sigue siendo tendencia por…» o «siguen siendo tendencia por…». Si se comprueba un episodio genuinamente distinto (p. ej., otro partido días después), marcar `distinct_episode:true`, explicar la diferencia en `reason/new_facts`, y usar el comienzo ordinario «es tendencia por…». Se exigen además `material_event_key` (clave semántica estable de ese HECHO concreto, no del nombre ni de la posición) y `material_event_at` (fecha/hora ISO8601 verificadas del acontecimiento, posteriores a la explicación anterior). No confundir hora de revisión, actualización de fuente ni recirculación de artículos con fecha del hecho. No deducir un episodio nuevo solo de que hayan pasado 48h. Solo asignar `material_change:true` ante un hecho independiente con efecto sustancial y justificación precisa en `significance_reason`; nunca por una variación menor ni por cambio de ID.

El aplicador conserva texto y fecha con `unchanged/unverified`, guardando `red_review_checked_at`, resultado y motivo aparte. Con `updated` de continuidad (mismo episodio), **SUSTITUYE la explicación y, si procede, el remate de la ficha original en los registros editoriales vigentes**, manteniendo exactamente su ID, revisión, fecha `explained_at`, estado de publicación, imagen de archivo/IA, asociaciones y recibos. **NO crea ficha en Listas, NO crea nueva imagen, NO vuelve a publicar ni manda otro paquete a Telegram/X/Instagram.** La fecha de la revisión solo se anota en `red_review_checked_at`. ÚNICAMENTE un acontecimiento genuinamente nuevo y significativo puede entrar de nuevo en Listas: `distinct_episode:true`, `material_change:true`, `significance_reason` de al menos 24 caracteres, fuentes verificadas, `material_event_key` nuevo y `material_event_at` posterior a `explained_at` original, con contenido factual distinto; entonces el aplicador crea una ficha nueva con su propio ciclo de imágenes. Si falta alguno de esos tres campos, tratar como continuidad y no generar otra imagen. Un cambio de redacción, orden del Top30, repetición del mismo hecho, nombre o ID no constituye un nuevo episodio. Una ficha anterior no publicada puede quedar marcada cubierta; una publicada conserva su estado e historial terminal. No incrementar contadores ni dar por publicada una actualización. Ante `review_error`, corregir el mismo resultado. Releer el job `review_completed` y los datos persistidos; no procesar como ready ordinario ni borrar el origen.

### Control de episodios repetidos

**Ejemplo obligatorio:** Óscar Puente continúa apareciendo en el Top 30 por noticias sobre su dimisión. Si la revisión no demuestra un acontecimiento posterior e independiente, resultado `unchanged` o `updated` de **continuidad**, sin ficha en Listas, sin nuevo ID y sin imagen. Ni repetir «dimisión», ni publicar más artículos sobre ella, ni cambiar del puesto 16 al 7 justifican un episodio distinto. Nunca introducir como `new_facts` algo que ya figuraba en la explicación anterior.

Para una novedad excepcional de episodio separado, registrar como mínimo:

```json
{"job_id":"ID_REVISION","outcome":"updated","reason":"Explicar qué hecho distinto ocurrió y su trascendencia","new_facts":"Hecho independiente no citado en el episodio anterior","distinct_episode":true,"material_change":true,"significance_reason":"Consecuencias verificadas concretas del nuevo suceso","material_event_key":"evento-concreto-estable-aaaa-mm-dd","material_event_at":"2026-11-05T09:00:00+01:00","explanation":"TT#16 Nombre es tendencia por un hecho nuevo verificado...","closer_text":"","verification_sources":[{"url":"https://FUENTE_REAL_DEL_HECHO"}]}
```

La fecha y la clave del ejemplo son **campos ilustrativos, no hechos reales**; jamás copiarlas sin verificación. Si falta la fecha, la clave o la independencia del episodio, guardar continuidad **actualizando el texto de la misma ficha**, si existe una explicación revisada verificable, sin alterar la imagen anterior, la fecha original, el ID ni la revisión. Si no hay nuevos datos para modificar la explicación, declarar `unchanged` y mantener el texto anterior. Nunca poner un timestamp de ahora solo para franquear el filtro.

## Cierre de la pasada

Releer la cola y los resultados aplicados. Verificar que cada revisión ordinaria cerrada coincide entre request y ficha, y que cada mantenimiento tratado tiene su resultado aplicado. Distinguir los pendientes de verificación de los pendientes de transporte. Registrar incidencias precisas con ID/revisión y primer eslabón ausente; no afirmar que una solicitud, un ACK o un workflow verde equivale a texto terminado, imagen entregada o publicación en X.

