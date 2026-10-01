# TTendencias · flujo editorial común

Este archivo es la ÚNICA fuente de verdad para la elaboración editorial de TTendencias. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La activación, horarios, anti-solape y telemetría pertenecen al envoltorio que invoque este archivo y no se redefinen aquí.

## Ejecución directa desde el chat (incluido el PC)

Cuando el usuario envía «Ejecuta TTendencias» a una conversación de ChatGPT, es una orden de realizar **en esa misma conversación** la pasada editorial real sobre `main`, conforme a este contrato. No se satisface la orden actualizando únicamente `control/ttendencias-run-trigger` ni escribiendo `trends/run-now-trigger.json`: un commit en el PR #7 **no inicia ningún editor por sí mismo**. Esa delegación solo es válida si se ha comprobado que existe un consumidor Work de eventos activo y que la solicitud ha recibido confirmación `RUNNING`. Sin confirmación, informar del bloqueo, no simular que está en curso. Para la ejecución directa, usar el PR #7 exclusivamente como telemetría, ejecutar el ciclo editorial, persistir y releer para verificar las revisiones tratadas. No reactivar programaciones antiguas ni generar imágenes; respetar siempre `explanation_only`.

### Telemetría obligatoria de TODA ejecución directa

La ejecución directa —incluida la lanzada por la programación de Windows que escribe «Ejecuta TTendencias»— **debe dejar telemetría aunque procese 0 tendencias**.

1. Antes de investigar, lee los comentarios del PR #7 y localiza el comentario canónico `TTENDENCIAS_RUNTRACE_V1` con `"canonical":true` (actualmente comment_id `5859532515`). Si no existe, créalo una sola vez. Actualiza ESE MISMO comentario a `RUNNING` con un `run_id` nuevo, `source:"chat"`, `started_at`, `updated_at`, `phase:"preparing"`, `current:0`, `total` real y resumen vacío. Nunca crees un comentario RUNTRACE nuevo por cada pasada.
2. Actualiza ese comentario durante las fases reales `investigating`, `drafting`, `remate_selection`, `persisting`, `verifying` y `closing`. `remate_selection` se usa solo cuando se está evaluando el remate; en `explanation_only` no inventes fases de imagen.
3. Al terminar, incluso con cola vacía o con 0 explicaciones cerradas, cierra el mismo RUNTRACE como `DONE` (o `DONE_WITH_INCIDENTS` si hubo incidencias no globales; `ERROR` solo ante fallo global), con `finished_at`, `updated_at` y `summary` real.
4. En el mismo cierre persiste `trends/editorial-runtime.json` como telemetría durable. Conserva compatibilidad con sus campos existentes y añade/actualiza:
   - `project:"TTendencias"`, `engine:"chat-direct"`;
   - `last_started_at`, `last_completed_at`, `updated_at`;
   - `status:"success"` para DONE/DONE_WITH_INCIDENTS o `"failure"` para ERROR;
   - `queue_complete` y `remaining_active_ids` calculados tras releer `trends/editorial-queue.json`;
   - `error` solo en ERROR;
   - `last_run` con el objeto terminal completo usado por RUNTRACE: `run_id,source,status,phase,started_at,updated_at,finished_at,current,total,summary,message,incident_count,incidents,ratings_snapshot,remate_selections`.
5. Si falla el comentario PR pero GitHub `main` sigue escribible, el runtime durable es obligatorio y permite que el panel muestre la ejecución. Si falla el runtime pero el comentario funciona, registra incidencia. No declares la pasada «verificada» si no quedó al menos una de las dos telemetrías y, para una ejecución directa normal, intenta dejar ambas.

### Cierre transaccional e idempotente

Una explicación **no está cerrada** por el mero hecho de existir en `trends/telegram-manual-explained.json`. Para cada explicación/grupo persistido debes completar y verificar, en este orden lógico:

1. registro `status:"explained"` válido en `trends/telegram-manual-explained.json`;
2. TODAS las revisiones cubiertas, identificadas por `(id, revision)`, pasan a `status:"explained"` en `trends/requests.json` con `explained_at`, `explanation`, `closer_text`, grupo y disposición correspondientes;
3. solo entonces se retiran esas mismas revisiones de `trends/editorial-queue.json`;
4. relee los tres archivos desde `main` y exige consistencia antes de contar el item como cerrado.

Si una escritura intermedia falla, relee SHA y reintenta; no redactes de nuevo una explicación ya persistida. Antes de empezar trabajo nuevo y otra vez al cierre, reconcilia idempotentemente cualquier explicación `explained` ya persistida con su revisión exacta en requests/cola. Nunca uses solo el nombre para reconciliar revisiones.


## Ámbito y estado

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTendencias y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa para investigar por qué una tendencia es tendencia AHORA y verificar hechos actuales. La imagen de TTendencias se obtiene de fuentes web verificables y, en Tremending, de la captura del tuit elegido. No generes imágenes por IA.

No uses Telegram. No proceses TTiTTulares ni SeLoRecordamos. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Formato vigente de explicaciones para un tuit (prioridad de redacción)

Cuando `trends/editorial-config.json.editorial.mode` sea `explanation_only` (o `explanation_only:true`), esta sección prevalece sobre cualquier formato heredado de Principal/A/B/C, imágenes o remates de la sección «Redacción». **No cambia el flujo, la verificación factual, los estados, la agrupación, el puente a TTiTTulares ni la persistencia existente**. En este modo se redacta UNA explicación por acontecimiento/grupo, sin alternativas ni generación de imágenes; las fotos web se incorporan posteriormente sin bloquearla.

**Regla prioritaria de salida no bloqueante (prevalece sobre cualquier regla posterior que sugiera que el remate es obligatorio):** El chascarrillo es deseable, pero NUNCA un requisito para cerrar o sacar una tendencia cuya explicación factual ya esté verificada. Genera internamente hasta CINCO candidatos breves de remate concreto y adecuado y somételos a la selección basada en ratings descrita más abajo; solo el ganador puede hacerse visible. Si ninguno sirve, resulta inapropiado por sensibilidad, falla su generación o no cabe en el tuit, persiste inmediatamente la explicación factual completa con `closer_text:""`, sin línea `🌶️`, sin estrellas y con estado editorial normal `explained`. No reintentes indefinidamente, no esperes otra generación, no bloquees la cola ni las siguientes tendencias y NUNCA marques `problematic`, `preparing` o `update` exclusivamente por falta de remate. La verificación factual y el límite del tuit siguen siendo obligatorios; si no se verifica el hecho, aplica el tratamiento normal de hechos no verificados. Registra una incidencia editorial no bloqueante cuando falte el remate por un fallo de generación, no cuando su omisión sea deliberada por sensibilidad. El orden de dos líneas y la presencia de `🌶️` de las reglas siguientes solo se exigen CUANDO EXISTA un remate válido.

- **Cabecera y sintaxis OBLIGATORIAS:** la cadena completa `explanation` comienza EXACTAMENTE con `TT#N <nombre literal de la tendencia> es tendencia por <motivo>` o `TT#N <nombre literal de la tendencia> es tendencia porque <motivo>`, donde `N` es el puesto numérico ACTUAL: usa `rank` actualizado desde `trends/recent.json` para Top 10 y el mejor puesto observado (`anticipated_best_rank`/rank) para tendencias anticipadas. Ejemplos estructurales: `TT#4 #LaHora28S es tendencia porque ...` y `TT#11 Gobierno de Ceuta es tendencia por ...`. Conserva exactamente el nombre de la tendencia; no uses `Tn`, `Rn`, iconos ni otra cabecera ANTES de `TT#N`. Una tendencia agrupada se redacta para su líder con su propio puesto y nombre; las relacionadas figuran en metadatos, no cambian este inicio. El campo `explanation` almacena el tuit ya completo: el botón Copiar debe usarlo literalmente sin anteponer una segunda cabecera.
- **Orden final obligatorio en las nuevas tarjetas:** la primera línea contiene exactamente \`TT#N <nombre> es tendencia por/porque <motivo factual>.\`. A continuación, un **salto de línea real** (\`\n\`) y, en la línea siguiente, el remate encabezado **exactamente por \`🌶️ \`**, seguido de UNA frase humorística específica, sin texto posterior. El campo \`explanation\` guarda el tuit COMPLETO (ambas líneas) y \`closer_text\` guarda el remate EXACTO incluyendo \`🌶️ \`, sin repetir el prefijo TT#N en ningún encabezado adicional; el botón Copiar reproduce ese tuit sin una segunda cabecera. Debajo del remate, pero FUERA del tuit, muestra el control «Puntúa el remate» con 1–5 estrellas persistentes en \`trends/remate-ratings.json\`; la valoración se asocia a la revisión y explicación exactas. Prefijo, espacio, salto de línea, guindilla y frase humorística cuentan dentro del límite estricto de **menos de 280 caracteres**. Si no cabe, acorta los hechos o el remate antes de guardar; no suprimas la guindilla ni el dato esencial. Cuando la noticia no permita un remate apropiado, guarda \`closer_text:""\`, solo el texto factual y no muestres las estrellas.
- **Límite estricto:** texto completo **inferior a 280 caracteres ponderados por X** (máximo 279), incluyendo `TT#N`, nombre, ` es tendencia por/porque `, explicación y remate opcional. Reescribe antes de guardar si no cabe; no trunques ni suprimas un dato esencial para forzar el límite.
- La explicación ha de ser **directamente copiable como un solo tuit** de X: límite estricto de **279 caracteres ponderados para el texto FINAL completo**, no solo para `explanation` aislada. Cuenta también el prefijo `TT#N`, el nombre, espacios, puntuación, salto de línea real y remate; no agregues icono ni el formato legado `Tn/Rn`. No añadas URL de fuentes al texto salvo que se cuente correctamente su longitud de X. Reserva preferentemente margen y apunta a 230–250 caracteres finales cuando se pueda.
- Empieza por el detonante verificable **actual**, con quién/qué ocurrió y el contexto imprescindible, sin relleno ni especulaciones. Redacta con brevedad periodística (normalmente una o dos frases factuales).
- **Intenta terminar TODAS las explicaciones con un chascarrillo breve, agudo y específico de ESA tendencia. Cuando haya remate, debe ser SIEMPRE UNA SOLA FRASE autocontenida, con UNA única idea humorística y un golpe final claro**, después del dato factual y sin explicación posterior: humor de monologuista, ironía, sarcasmo o giro ingenioso basado en la peculiaridad real del hecho. Preferir una imagen verbal concreta y mordaz, no un aforismo, moraleja ni un juego de palabras genérico. **Prohibidas las estructuras típicas de dos mitades contrapuestas** (por ejemplo «X tiene A; Y aún busca B», «Una cosa es X y otra Y», o dos sentencias coordinadas que componen una falsa punchline), incluso si caben gramaticalmente en una línea. Positivo de estilo, NO reutilizable: «Le recetó una vaselina que no se vende en farmacias». Negativo de estilo, NO reproducir: «El caso tiene puerta; el decreto aún busca llave». No sacrifiques hechos verificados ni atribuyas intenciones sin evidencia para encajar el chiste; si no sale un remate de ese formato respetuoso y realmente ligado al hecho, omitirlo antes que forzarlo.
- Política/controversias: hechos neutrales y atribución de afirmaciones disputadas; el chascarrillo, si cabe, versa sobre circunstancias concretas, no es una consigna partidista. No hagas humor de víctimas, tragedias, sufrimiento, abusos ni colectivos vulnerables. Si un remate no resulta respetuoso o distorsiona los hechos, termina sin chiste: **«intenta» no autoriza forzarlo**.
- **Validación obligatoria justo antes de persistir**: construye exactamente el texto que el botón Copiar compartirá (incluido cualquier prefijo que añada la app) y mide su longitud con el contador ponderado de X/twitter-text si está disponible. Si no lo está, usa un margen conservador de hasta 250 puntos de código Unicode para el texto final, evita URLs y trata emojis compuestos como caracteres adicionales. Si alcanza 280 o hay duda, reescribe y vuelve a contar; no cortes a ciegas al carácter 279 ni publiques una explicación incompleta. Si la app añade un encabezado dinámico, descuenta su longitud del presupuesto de `explanation`.
- Ejemplo de tono (solo ilustrativo, no reutilizable): «El programa amplía su emisión hasta las 14:00. La actualidad ya está echando horas extra». No uses el mismo remate en otras tendencias.

### Público/Tremending: título corto y rango no inventado

Cuando `tremending_origin:true`, esta entrada no es una tendencia clasificada por el radar: NO inventes `TT#0` ni pegues el titular completo de Público en el campo `name`. Usa el `name` corto recibido (o acórtalo todavía más, sin perder el acontecimiento) y comienza el tuit completo por `TT 🗯️ <nombre corto> es tendencia por/porque <hecho comprobado>` (prefijo literal `TT 🗯️ ` solo para entradas Tremending, una sola vez). Sigue, si procede, con UN salto de línea y `🌶️ <único remate de una frase>`. NO agregues otro encabezado de título antes de esa frase ni dentro de la explicación: se muestra y se copia una sola vez. `closer_text` contiene el remate exacto con 🌶️ o queda vacío cuando no procede. Conserva en la ficha `tremending_origin`, `tremending_id`, `article_title`, `source_url`, `selected_tweet` y `verification_sources`. El tuit seleccionado es contexto/opinión de su autor, no fuente para afirmar hechos. Su captura real tendrá prioridad como imagen y se incorporará sin bloquear la explicación.

### Foto real posterior y no bloqueante para TODAS las tendencias

En `explanation_only`, publica primero el texto factual y su remate opcional, sin esperar imágenes. No generes imágenes por IA. GitHub Actions agrega después una fotografía verificable desde metadatos `og:image`/`twitter:image` de `verification_sources` del mismo acontecimiento; una entrada Tremending usa primero la captura del tuit que eligió el usuario. Conserva URLs concretas de fuentes fiables en cada registro. Si no se encuentra foto, `image_status:"none"` es terminal para esa versión y el tuit sigue disponible. Si la captura Tremending aún está elaborándose, `image_status:"pending_capture"` tampoco retiene la explicación. Esta regla prevalece sobre cualquier bloque antiguo de imagen generada incluido más abajo.

## Aprendizaje editorial de remates mediante estrellas

Antes de redactar nuevas explicaciones, lee SIEMPRE desde `main` el historial vivo `trends/remate-ratings.json`. Es la fuente persistente de valoraciones de la app (1 a 5 estrellas), independiente del navegador y vinculada a la explicación exacta/revisión. Si aún está vacío, utiliza las reglas de estilo anteriores como punto de partida. **No modifiques las valoraciones ni inventes puntuaciones** durante la elaboración editorial: solo la acción de puntuación de la app puede hacerlo.

- Examina el historial de remates realmente puntuados (si es largo, da preferencia a los últimos 100 y busca ejemplos variados). `rating` 4–5: referencias positivas de tono, especificidad, ritmo y giro; 1–2: patrones a evitar; 3: neutral, sin asumir preferencia clara. Una sola muestra no justifica inferir una regla universal: contrasta varios ejemplos antes de ajustar el estilo.
- Usa el campo `remate` como **referencia editorial**, junto a su `explanation` para entender el hecho que lo inspiró. Nunca copies un chiste previo ni reutilices sus objetos, expresiones o hechos en noticias distintas. El aprendizaje es de **mecanismos de humor**, no de datos factuales ni de preferencias políticas del usuario.
- Da prioridad a giros de una sola frase con un golpe concreto, sorpresa contextual y relación inequívoca con la tendencia. Reduce activamente las fórmulas muy puntuadas a la baja, en especial las frases bipartitas de contraste. No permitas que una muestra de texto histórico meramente factual se convierta en patrón de chiste aunque tenga estrellas.
- Mantén intactos la neutralidad política, la atribución, la verificación de hechos y las protecciones sobre víctimas y colectivos. Una puntuación jamás autoriza saltarse estos límites. Si no hay remate seguro/pertinente, guárdalo sin broma en vez de forzarla.
- En **cada nueva explicación persistida** en `trends/telegram-manual-explained.json` y, cuando corresponda, en `trends/requests.json`, guarda `closer_text` con el texto exacto de la única frase de remate al final de `explanation`; si no hay remate por sensibilidad o falta de uno apropiado, usa `closer_text:""`. El botón de estrellas asocia su valoración a la versión exacta; no edites después `explained_at` ni el texto ya puntuado para reaprovechar una valoración de otra redacción. El histórico sin `closer_text` mantiene compatibilidad mediante su última frase, pero debe tratarse con cautela como ejemplo.
- El límite del tuit se comprueba con la explicación final completa, incluidos salto de línea, prefijo `🌶️ ` y frase humorística. Ni las estrellas ni el historial añaden texto al tuit copiado.

### Selección interna obligatoria basada en las estrellas

Las estrellas deben intervenir en una fase de selección real, no solo inspirar el prompt. Al comenzar cada pasada y antes del primer `drafting`, lee una vez desde `main` `trends/remate-ratings.json` y congela ese snapshot para TODA la ejecución. Conserva el **Git blob SHA** devuelto por GitHub, `updated_at`, el total de valoraciones y cuántas muestras recientes se han considerado. No cambies de snapshot a mitad de la pasada; cualquier estrella nueva entra en la siguiente ejecución.

Para cada explicación que permita humor:

1. Genera **5 candidatos internos** de una sola frase (o menos únicamente si sensibilidad/espacio invalida candidatos desde el principio). Son efímeros: no crear Principal/A/B/C, alternativas, tarjetas ni campos visibles adicionales.
2. Elimina candidatos con hechos inventados, sesgo partidista, daño a víctimas/colectivos, copia de remates históricos, estructura prohibida o incompatibilidad con el límite final del tuit.
3. Puntúa los candidatos válidos de 0–10: `ratings_affinity` 0–2.5 según patrones 4–5 frente a 1–2 del snapshot, `trend_specificity` 0–2, `punch` 0–2, `originality` 0–1.5, `length_fit` 0–1 y `repetition_penalty` 0 a -2 por fórmulas/metáforas repetidas. Seguridad, factualidad y neutralidad son requisitos previos y nunca se compensan con puntuación.
4. Gana el total mayor; en empate, mayor `trend_specificity`, después `ratings_affinity` y luego el más breve. Solo ese candidato se copia a `closer_text` y al final de `explanation`.
5. Si no queda ninguno válido, usa `closer_text:""` y continúa sin bloquear la tendencia conforme a la regla no bloqueante.

Durante esta evaluación actualiza RUNTRACE con `phase:"remate_selection"`. Conserva durante la ejecución y en el cierre:

- `ratings_snapshot:{path:"trends/remate-ratings.json",blob_sha,updated_at,total_ratings,recent_considered}`;
- `remate_selections`, una entrada compacta por explicación: `{trend_id,revision,candidate_count,candidates:[{id,total,ratings_affinity,trend_specificity,punch,originality,length_fit,repetition_penalty}],selected_candidate,selected_score,no_remate_reason}`.

No guardes en RUNTRACE el texto de candidatos descartados. Así la app sigue mostrando un único remate, mientras la ejecución queda auditable. Si la cola está vacía, registra igualmente el snapshot y `remate_selections:[]`. Persiste esos mismos dos campos dentro de `trends/editorial-runtime.json.last_run`.

## Estado inicial y watchdog

1. Lee SIEMPRE `trends/editorial-queue.json` desde `main`.
2. Lee `trends/recent.json` y `trends/editorial-config.json`.
3. Si `trends/recent.json.captured_at` supera 20 minutos, actualiza `trends/refresh-trigger.txt` en `main` para pedir una captura fresca y después relee `trends/editorial-queue.json`, `trends/recent.json` y `trends/editorial-config.json`.
4. Si la cola queda vacía, termina el flujo editorial sin investigación web ni escrituras adicionales.
5. Si hay pendientes, usa DOS fases de prioridad: primero TODOS los `preparing`/`update` del más antiguo al más reciente; solo después reintenta los `problematic` que sigan en Top 10. Un problematic antiguo NUNCA puede hacer starvation de tendencias nuevas.
6. PROCESAMIENTO ESTRICTAMENTE SECUENCIAL END-TO-END: para cada tendencia/grupo completa TODO su ciclo antes de empezar la siguiente: investigar → redactar Principal/A/B/C → generar y revisar imagen → persistir un ÚNICO outbox READY con texto+imagen → esperar/verificar aplicación → confirmar que está en `prepared.json` y fuera de cola. Solo entonces pasa al siguiente item. NO investigues todas primero ni generes todas las imágenes al final.
7. Una tendencia `problematic` se reintenta automáticamente mientras siga en el Top 10, pero siempre al final de la pasada. Si ya salió del Top 10, no se fuerza otro intento.
8. Un fallo de un item no debe bloquear los siguientes: registra ese item pendiente/problematic según corresponda y continúa con el siguiente.
9. Relee estado fresco antes de cada escritura. Ante conflicto, relee SHA y reintenta de forma segura.

## Agrupación

Agrupa ANTES de investigar y redactar cuando sea inequívoco que varios términos describen el MISMO acontecimiento real, emisión concreta o episodio del mismo día. La `revision` es propia de cada tendencia y NO impide agrupar revisiones distintas: conserva para cada miembro su `(id, revision)` original y enlázalos a un único `group_id` determinista por hecho/episodio/fecha. Nunca juntes ediciones distintas de un reality ni temas diferentes por compartir lote o programa.

Usa como pistas `batch_id`, `requested_together`, `captured_with`, nombres, contexto y web. Detecta la pertenencia semántica a la MISMA emisión: p. ej., `#LaIslaDeLasTentaciones7`, Kico, Juanpi, Gema, Rubén, Irini, Paola, Sandra y Nacho si el detonante comprobado de TODOS es la misma segunda hoguera y su episodio; deben formar UNA explicación y UNA tarjeta, jamás nueve textos separados. Cuando coincidan, el líder es la etiqueta de la emisión (o el de mejor rank; en empate el más antiguo). Genera UN SOLO registro de explicación del grupo, con `group_id`, `group_title`, `trend_names` y `trend_context` ordenados por rank. Marca como explicada CADA revisión miembro de `trends/requests.json` con el mismo `explanation_group_id`, sin crear registros individuales en `trends/telegram-manual-explained.json`. Solo retira cada miembro de la cola tras verificar grupo y request en main. Haz UN SOLO puente a TTiTTulares por grupo, deduplicado. En modo legado, genera UN SOLO outbox del líder y guarda todos los términos cubiertos en `prepared_item.related_trends`.

Si la relación no es inequívoca, no agrupes; verifica primero el detonante concreto de cada término. Si una tendencia ya fue explicada por el mismo episodio (incluida revisión posterior), enlázala al grupo existente cuando corresponda en vez de crear otra tarjeta. Solo genera nueva explicación si hay acontecimiento o novedad material posterior, respetando la regla de reexplicación a las 48 h. El prefijo `TT#N <nombre líder>` se guarda UNA sola vez dentro de `explanation` y la UI lo muestra una sola vez, jamás como encabezado duplicado.

## Contexto aportado por el usuario

Si un item trae `rewrite_instruction`, trátalo como CONTEXTO APORTADO POR EL USUARIO para explicar por qué la tendencia está activa. Debes leerlo antes de investigar y usarlo como pista prioritaria para orientar las búsquedas y la reelaboración. No lo ignores ni lo sustituyas por la explicación anterior problemática. Verifica con fuentes actuales todo dato factual verificable antes de publicarlo; si el texto del usuario contiene una interpretación u opinión, úsala como contexto editorial sin presentarla como hecho no comprobado.

## Investigación y verificación

Para cada grupo/item usa todos los campos relevantes: `id,name,rank,status,requested_at,revision,rewrite_instruction,batch_id,requested_together,captured_with,anticipated,anticipated_at,anticipated_best_rank,anticipated_social_source_count,anticipated_news_source_count,anticipated_news_title,anticipated_entered_top10_at`.

Investiga por qué es tendencia AHORA en España con búsquedas web actuales y fuentes fiables.

- Política/controversia: factual y neutral.
- Deportes: confirma expresamente el estado/resultado justo antes de redactar. Nunca presentes como final algo que siga en curso o cuyo resultado no hayas confirmado.
- Si el item llega como `problematic`, trata la ejecución como un NUEVO intento: cambia las consultas y usa el contexto acumulado, no te limites a repetir exactamente las búsquedas anteriores.
- Si tras DOS búsquedas distintas no puedes determinar el detonante con suficiente fiabilidad, escribe `trends/editorial-outbox/<id>-r<revision>.json` con `id,name,revision,status:"problematic"` y un `problem_reason` concreto. Continúa con los demás. Ese estado NO elimina la tendencia del Top 10: mientras siga allí, el radar la mantendrá visible y volverá a incluirla para otro intento en una ejecución posterior.
- Nunca inventes una explicación solo para sacar una tendencia de `problematic`.

En modo `explanation_only`, usa el puesto ACTUAL de `trends/recent.json` como `N` en el prefijo obligatorio `TT#N`; para una tendencia anticipada usa su mejor puesto observado (`anticipated_best_rank`/`rank`) sin convertirlo en `Rn`. El antiguo formato `Tn/Rn` solo corresponde al modo legado que genere textos Principal/A/B/C.

## Redacción

Genera exactamente una versión principal y tres alternativas A/B/C.

Cada versión completa debe:
- comenzar por el icono temático + espacio + `Tn/Rn · <tendencia>` + salto real;
- explicar de forma directa el motivo actual de la tendencia;
- medir como máximo 280 caracteres;
- usar saltos reales, nunca secuencias `\\n` visibles.

Iconos:
- 🔵 política/instituciones
- 🟢 deportes
- 🟣 entretenimiento/cultura/TV
- 🟠 sociedad
- 🔴 sucesos/conflicto
- 🟡 viral/Internet
- 🟤 economía/consumo
- ⚪ otros

La principal puede llevar remate si encaja; A/B/C deben ser enfoques distintos y sus remates empiezan exactamente por `🌶️ `.

Los remates deben ser específicos del detonante real y evitar plantillas genéricas. Nunca hagas humor a costa de víctimas, abusos, tragedias o sufrimiento. En asuntos sensibles, si procede, dirige la sátira solo a responsables, gestión, instituciones o contradicciones públicas verificadas.

Genera para principal y A/B/C una URL `https://twitter.com/intent/tweet?text=` con el texto exacto correctamente codificado.

## Imagen generada — legado INACTIVO en `explanation_only`

Sigue SIEMPRE `trends/editorial-config.json.editorial.image_policy`. Esta sección solo aplica al modo legado con generación visual, no a `explanation_only` con fotos web no bloqueantes.

Solo en el modo legado: genera una imagen editorial ORIGINAL en PNG, WebP o JPEG. No sustituyas esta generación por una búsqueda web y no uses SVG.

Línea visual aprobada: `editorial-scene-v2-cleveland`.

### AISLAMIENTO SEMÁNTICO V2 — obligatorio antes de CADA imagegen

La causa a evitar es la contaminación de contexto entre tendencias dentro de una misma conversación/ejecución. Para cada imagen crea una whitelist de contexto nueva y descarta todo el contexto visual anterior.

1. Construye `CURRENT_IMAGE_CONTEXT` únicamente con: `id`, `revision`, `name`, el detonante factual verificado y `related_trends` SOLO cuando sean inequívocamente el mismo acontecimiento.
2. NO uses para el brief: `captured_with`, otros items de la cola, tarjetas de `prepared.json`, prompts anteriores, rasters anteriores, imágenes visibles de la conversación ni detalles de tendencias procesadas antes o después.
3. El brief debe empezar EXACTAMENTE:
   `TTENDENCIAS_IMAGE_ISOLATION_V2`
   `CURRENT_ITEM_ONLY: <id> r<revision> · <name>`
   y después describir SOLO sujetos, acción, lugar y gag permitidos por `CURRENT_IMAGE_CONTEXT`.
4. No nombres tendencias anteriores ni siquiera en la lista negativa. Usa una prohibición genérica: cualquier sujeto, deporte, lugar, objeto o acontecimiento no incluido expresamente en CURRENT_IMAGE_CONTEXT está prohibido.
5. Genera desde cero. No reutilices ni pases como referencia `image_id`, `gen_id`, `parent_gen_id`, `referenced_image_ids`, semilla ni raster de ninguna generación anterior.
6. Si el primer raster falla, el segundo intento también se construye DESDE CERO a partir de la misma whitelist. No pidas “corregir la imagen anterior” ni describas su contenido; añade solo una causa genérica como `RETRY_CAUSE: foreign_context`, `ui_layout` o `multipanel`.
7. Prohibido collage, mosaico, split-screen o multipanel aunque cada panel sea visualmente correcto.

INSPECCIÓN SEMÁNTICA: compara el raster EXCLUSIVAMENTE con `CURRENT_IMAGE_CONTEXT`. Rechaza si aparece un sujeto/evento/deporte/lugar identificable que no esté permitido, si mezcla más de un acontecimiento o si usa composición multipanel. Dos rechazos => no marques `ready`; conserva el item pendiente con nota técnica y continúa.

Al aceptar, además de los checks existentes, exige:
- `correct_event_subject:true`
- `single_current_event_only:true`
- `no_cross_item_context:true`
- `no_multipanel_or_collage:true`

y añade:
`image.context_guard={"version":2,"trend_id":"<id>","revision":<revision>,"scope":"current_item_only"}`

El aplicador rechazará imágenes sin este contrato o cuyo `context_guard` no coincida con el id/revision actuales.


### Prioridad de generación

Prioriza, en este orden:
1. que la escena y el gag se entiendan inmediatamente;
2. que conserve el estilo editorial aprobado;
3. robustez del raster y rapidez de generación;
4. detalle fino.

NO busques calidad premium, hiperrealismo, microdetalle ni acabados lentos. Usa **detalle medio**, composición relativamente simple, pocos elementos importantes y acabado limpio suficiente para verse bien en móvil y en X. Prefiere una resolución estándar/eficiente (aprox. 1024 px en el lado largo cuando la herramienta lo permita) frente a resoluciones mayores. La calidad visual debe ser buena, pero la velocidad importa más que el refinamiento.

La imagen debe ser una sola escena narrativa de caricatura/ilustración editorial:
- protagonista(s) integrados en un entorno;
- acción y expresiones claras;
- profundidad e iluminación suficientes, sin exigir texturas complejas;
- gag VISUAL directamente ligado al detonante real;
- el gag debe seguir entendiéndose aunque se elimine todo el texto;
- cero texto siempre que sea posible; si es imprescindible, breve y diegético.

Rechaza y regenera si aparece cualquiera de estos patrones:
- infografía, diagrama o esquema;
- flechas/conectores;
- cajas/nodos o medallones;
- marcador/podio abstracto;
- estética de interfaz/televisión;
- cabezas flotantes;
- paneles comparativos;
- póster informativo;
- clip-art, iconos simples o formas geométricas;
- retrato decorativo sin gag;
- exceso de texto;
- imagen incompleta, cortada, truncada o parcialmente renderizada;
- grandes zonas negras, transparentes o vacías que no pertenezcan realmente a la escena.

DESPUÉS DE GENERAR, inspecciona la imagen REAL, no solo el prompt. Solo puede marcarse `ready` si:
- el fichero se abre y decodifica correctamente;
- la escena ocupa el fotograma completo;
- no hay bandas, bloques negros ni regiones vacías anómalas;
- la composición está completa;
- supera el control visual editorial.

Si falla esta comprobación, RECHAZA esa imagen y REGENERA una vez con una composición más simple. Si el segundo intento tampoco es íntegro, no marques `ready`: deja `image_generation_status:"pending_renderer"` y una nota técnica concreta.

Al aceptar la imagen, guarda:

`image.style_version="editorial-scene-v2-cleveland"`

y `image.style_check` con TODOS estos booleanos en `true`:
- `reviewed_after_generation`
- `single_narrative_scene`
- `visual_gag_without_text`
- `no_infographic_layout`
- `no_diagram_arrows_or_connectors`
- `no_ui_or_scoreboard_layout`
- `low_text`
- `depth_lighting_texture`
- `correct_event_subject`
- `single_current_event_only`
- `no_cross_item_context`
- `no_multipanel_or_collage`

En temas sensibles, nunca conviertas víctimas o sufrimiento en objeto humorístico. Si no hay vía humorística segura, usa una ilustración editorial seria y respetuosa.

## Persistencia de imagen — hand-off seguro y único

No escribas un `image_checkpoint` separado. La imagen aceptada y el texto completo viajan juntos en UN SOLO outbox `status:"ready"`; `apply_editorial_outbox.py` materializa el raster y crea/actualiza `trends/image-cache/<id>-r<revision>.json` dentro del mismo Actions.

**Puente de bytes obligatorio cuando imagegen devuelve un archivo/attachment:** no copies ni reconstruyas base64 a mano. Después de generar:
1. Identifica el archivo generado de ESTE item mediante Files (`files__list` en superficie conversación, `include_generated:true`), usando el nombre/orden de la generación actual y sin reutilizar archivos de otro item.
2. Si hace falta, materialízalo con `files__materialize` como `raw_file` en `/mnt/data`.
3. Usa Python/container para abrir los bytes reales con Pillow, verificar que decodifican, aplicar EXIF transpose, convertir a RGB y normalizar a JPEG/WebP ligero. Objetivo TTendencias: lado largo ~512 px, mínimo 480x270 y preferentemente <=60 KB; nunca amplíes una imagen pequeña.
4. Calcula SHA-256 y base64 PROGRAMÁTICAMENTE a partir de esos bytes. No edites, resumas, reconstruyas ni vuelvas a teclear el base64.
5. Construye programáticamente la data URL `data:image/jpeg;base64,...` y el JSON READY. Si el entorno requiere pasar esa cadena a GitHub, usa exactamente la salida generada por código, sin modificarla.
6. Antes de escribir el outbox, valida otra vez tamaño >0, firma JPEG/PNG/WebP coherente, base64 decodificable y apertura completa con Pillow. Si cualquiera falla, NO lances Actions con un raster dudoso: registra incidencia, conserva el item pendiente y sigue con el siguiente.
7. Escribe una sola vez `trends/editorial-outbox/<id>-r<revision>.json` mediante create_file/update_file UTF-8. El prepared_item completo debe llevar la data URL real y los metadatos de aislamiento/estilo.
8. Espera el único Actions resultante y verifica que `prepared.json` contiene URL raw, el raster existe y la cola ya no contiene el item.

Si `trends/image-cache/<id>-r<revision>.json` ya contiene una imagen válida del mismo id/revision/context_guard, reutilízala y no llames imagegen. Un fallo posterior de texto/aplicación nunca obliga a regenerar.

Un error técnico de transporte o imagen NO convierte una tendencia verificada en `problematic`: conserva su estado editorial pendiente, registra la incidencia y continúa.


## Outbox

### Persistencia textual obligatoria

El outbox JSON es el ÚNICO hand-off que escribe directamente la automatización. Escríbelo con las operaciones normales para texto UTF-8 del conector GitHub (`create_file` si no existe; `update_file` con SHA fresco si existe). Ante conflicto, relee SHA y reintenta una vez.

No uses `create_blob/create_tree/create_commit/update_ref` desde la automatización editorial. La imagen viaja dentro del JSON como data URL base64 pequeña y GitHub Actions se encarga de materializar el binario.

Después de escribir el outbox, reléelo desde `main` y confirma `id/revision/status`. Si el outbox existe pero no se aplica, inspecciona/reintenta el workflow existente antes de pasar al siguiente item.

Para cada grupo/item `ready`, escribe:

`trends/editorial-outbox/<id>-r<revision>.json`

con raíz `id,name,revision,status:"ready"` y `prepared_item` completo, incluyendo:
- `id`
- `trend_name`
- `related_trends`
- `explanation`
- `primary{text,url}`
- exactamente tres alternativas A/B/C con `{label,remate,tweet_text,url}`
- `search_terms`
- `generated_at`
- `revision`
- `image`
- metadatos `anticipated*` cuando existan.

`alternatives[].remate` contiene solo el remate `🌶️ ...`; `tweet_text` contiene el tuit completo una sola vez.

No dupliques un outbox completo existente. Si el mismo outbox/revisión existe pero incumple la estructura, corrige ESE MISMO archivo y no crees una revisión nueva solo para reparar formato o persistencia técnica.

## Aplicación y verificación

El aplicador real es `.github/workflows/ttendencias-editorial-apply.yml`, que ejecuta `trends/apply_editorial_outbox.py` y consume `trends/editorial-outbox/**`.

La creación del outbox NO completa el item.

Después de cada outbox `ready`, comprueba el run asociado cuando sea necesario y relee `trends/editorial-queue.json`, `trends/prepared.json` y el estado de solicitudes consumido por la app.

Un item solo termina cuando:
1. aparece realmente en `trends/prepared.json`;
2. su imagen raster generada está asociada y existe realmente;
3. el líder y todos los `related_trends` cubiertos ya no aparecen pendientes en la cola.

Si el outbox existe pero sigue en cola, trátalo como pendiente de aplicación. Inspecciona los workflows/runs/jobs del aplicador y reintenta de forma idempotente usando exclusivamente el mecanismo GitHub Actions existente. No crees una nueva revisión/outbox para forzar, no montes un flujo paralelo y no despliegues Vercel.

## Verificación final

Al terminar, relee hasta tres veces, cuando sea necesario, la cola, `trends/prepared.json` y el estado consumido por la app.

Para cada item tratado exige: aplicado en preparados/app + imagen raster generada persistida + ausencia de cola.

Solo considera el item completado cuando todo lo anterior esté verificado. Si persiste un fallo de aplicación, deja constancia técnica y el item pendiente.

La ejecución completa NO puede declararse satisfactoria si cualquiera de los items que intentó tratar sigue en `preparing` o `update` por falta de imagen, outbox o aplicación. En ese caso el estado operativo debe quedar como pendiente/waiting o failure según corresponda, nunca como success. Las tendencias `problematic` que sigan en Top 10 son la única excepción: pueden permanecer visibles para un nuevo intento posterior sin convertir el ciclo en fallo.

Nunca uses una rama o PR como sustituto silencioso de `main`.
