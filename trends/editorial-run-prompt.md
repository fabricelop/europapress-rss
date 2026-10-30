# TTendencias · flujo editorial común

## Agrupar tendencias de Listas — orden explícita de la app (30/10/2026)

Antes del trabajo normal, atiende las entradas vigentes `listas_grouping_request:true`
(`task:group_listas`) en requests/cola. SON SOLICITUDES DE REVISIÓN, no tendencias
llamadas «Agrupar tendencias de Listas». Inspecciona TODAS sus `grouping_candidates`,
relee el estado real por ID/revisión y compara el texto con su snapshot.

Busca grupos que compartan un mismo acontecimiento o contexto noticioso concreto
y actual. No agrupes solo por persona, palabra, partido o tema genérico. Puedes
crear varios grupos independientes. Investiga y contrasta el motivo común; redacta
UNA nueva explicación publicable por grupo, TT#N + nombre/tema + hechos, hashtags
y un único remate cuando sea pertinente (<280 caracteres ponderados X).

**Instrucción expresa del usuario: NO CAMBIAR las explicaciones originales**, ni
su remate, fecha, revisión o imágenes. Se conservarán en Listas con metadatos
`listas_group_role:covered`, `covered_by_id` y `covered_by_name`, para retirarlas
fácilmente. La ficha nueva es `listas_group_role:joint` y es la única publicable.
No escribas esas marcas a mano y no uses el reconciliador de grupos ordinario
para este caso: copiaría textos o retiraría miembros sin el estado solicitado.

Persiste exclusivamente el resultado en
`trends/listas-grouping-outbox/<job_id>.json` con:

```json
{"job_id":"listas-grouping-UUID","groups":[{"name":"Tema común concreto","explanation":"TT#2 ...\n#Etiqueta1 #Etiqueta2","closer_text":"","reason":"Motivo comprobado por el que estas fichas cubren el mismo acontecimiento","verification_sources":[{"url":"https://fuente-verificada.example/documento"}],"members":[{"id":"ID1","revision":0},{"id":"ID2","revision":1}]}]}
```

El ejemplo de URL es un marcador de formato: usa fuentes reales verificadas.
Cada grupo necesita al menos dos miembros vigentes del snapshot, sin solaparse;
las tendencias sin relación se conservan intactas. Si no hay coincidencias, guarda
`groups:[]`. Ante `grouping_error`, corrige el MISMO outbox, no dupliques el job.
El workflow `ttactualidad-group-listas.yml` aplica el resultado transaccionalmente
con JIT y preserva los textos. Relee requests/catálogo/cola: solo está terminado
cuando el job es `grouping_completed` y cada ficha creada/cubierta está persistida.
Los grupos cuyos miembros fueron borrados o reelaborados se omiten enteros y se
registran en `grouping_skipped_stale`; no los resucites ni inventes revisiones.
No generes imágenes en esta pasada ni publiques en X. No pidas estrellas.


> **OPERATIVA VIGENTE · 17/10/2026 · PRIORIDAD ABSOLUTA**: TTActualidad es la interfaz editorial (móvil y alternativa GitHub Pages). Se han retirado las entregas de noticias y tendencias a Telegram: cualquier párrafo antiguo de este documento que exija enviar, editar o verificar tarjetas editoriales de Telegram queda OBSOLETO y NO se ejecuta. El cierre editorial real es la persistencia y relectura en GitHub main del texto factual, hashtags y remate, con READY/Listas en TTiTTulares o explained/Explicadas en TTendencias. Nunca bloquear ese cierre por foto de archivo, imagen IA o entrega Telegram. No invocar ImageGen durante la pasada editorial. Las imágenes se generan individualmente en ChatGPT Images y un proceso Windows las descarga al PC y las envía de forma independiente a TTImages; esta pasada no modifica ni activa ese transporte. Mantener intactos SeLoRecordamos, TTImages y FabCalendar. El trabajo PROCESSING/preparing sigue pendiente hasta persistencia verificada, no solo solicitud de ejecución.


## Regla prioritaria de hashtags para los tuits de TTendencias (14/10/2026)

**Petición expresa del usuario; prevalece sobre el formato histórico de solo dos líneas.** En CADA nueva explicación de una tendencia, incluyendo revisiones y Tremending, añade **dos hashtags** formados por palabras clave del acontecimiento verificado, o **tres** cuando aporten precisión y quepan en el tuit. Prioriza protagonista, evento, institución, equipo o lugar directamente ligados al motivo actual. Evita etiquetas genéricas (#Actualidad, #Noticias, #Viral, #España), repetidas, especulativas o propagandísticas. Si el nombre literal de la cabecera ya es un hashtag (p. ej. `#BenidormFest2027`), **no lo repitas** en la línea de etiquetas: selecciona otras dos palabras clave comprobadas, o tres si aportan precisión y caben. Escribe grafías legibles sin espacios (#BenidormFest2027, #LadillaRusa, #MargaritaRobles), sin alterar el nombre literal que acompaña a `TT#N`.

**Formato del campo `explanation` / tuit copiable:**
```text
TT#N <nombre literal> es tendencia porque <hecho verificado>.
#EtiquetaEspecifica1 #EtiquetaEspecifica2 [#EtiquetaEspecifica3]
🌶️ <Remate único y exacto>
```
Los corchetes son solo notación de opción, no texto literal. El remate va **siempre al final**, sin texto posterior; `closer_text` guarda exclusivamente `🌶️ ...`, nunca hashtags. Si no corresponde remate por sensibilidad o en los supuestos no políticos permitidos, conserva los dos o tres hashtags como **última línea**, sin inventar `🌶️`. Los campos `explanation` de `trends/requests.json` y `trends/telegram-manual-explained.json` deben ser **idénticos** para la misma revisión. El límite sigue siendo **menos de 280 caracteres ponderados por X** para el mensaje completo, **incluidas las etiquetas**. Acorta el bloque factual sin perder hechos esenciales; si no caben tres hashtags usa dos. No cambies el inicio obligatorio `TT#N` ni el prefijo especial `TT 🗯️` de Tremending, ni dupliques tarjetas, imágenes o remates por este cambio. Aplica esta estructura a nuevas explicaciones/revisiones; conserva las tarjetas explicadas, borradas, puntuadas o entregadas anteriormente sin edición retroactiva.

## Regla prioritaria: ningún aviso Telegram queda huérfano (12/10/2026)

Prevalece sobre cualquier instrucción heredada de excluir revisiones agrupadas o archivadas de la auditoría. **Ninguna tarjeta de Telegram o app puede borrarse por deduplicación sin una decisión explícita del usuario sobre esa tarjeta.** Una explicación conjunta no autoriza borrar otros avisos existentes: reutiliza el texto factual verificado para cerrar **cada `telegram_message_id` provisional** editando ese mismo mensaje. Conserva el motivo del agrupamiento y evita inventar hechos o remates.

Al abrir CADA pasada, y otra vez antes de cerrar 0/0, consulta `trends/telegram-image-deliveries.json`, `telegram/orphan-audit-ttendencias.json`, `trends/requests.json`, `trends/editorial-queue.json` y las explicaciones. **Todo `status:"sent",final:false` sin borrar expresamente es trabajo de reparación editorial**, incluso si un job anterior marcó `explained`, `inactive` o `grouped` y retiró su ID de la cola. Todas las pendientes del Top 30 siguen el flujo automático habitual. Elaborar con la información verificable disponible; si falta, buscar fuentes, no inventar ni ocultar la tarjeta.

Tras cada ejecución, despacha/verifica `send-ttendencias-explained-telegram.yml`; coteja identificadores y el estado postenvío con `telegram/orphan-audit-ttendencias.json`. Una cola editorial vacía **no significa** que Telegram esté limpio. Si la actualización no es posible, conserva el provisional y documenta la causa para el aviso Telegram de la auditoría; no cierres en falso. La API Bot Telegram no permite leer retrospectivamente el chat entero, de modo que valida confirmaciones API y ledger, sin afirmar inspección literal del historial.



Este archivo es la ÚNICA fuente de verdad para la elaboración editorial de TTendencias. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La activación, horarios, anti-solape y telemetría pertenecen al envoltorio que invoque este archivo y no se redefinen aquí.

## Selección obligatoria para cada pasada (Top 30)

Antes de investigar, relee `trends/recent.json`, `trends/editorial-queue.json`, `trends/requests.json` y los registros de explicaciones. **Regla vigente del usuario, 30/10/2026:** todas las tendencias pendientes de los puestos **1–30** entran automáticamente en `preparing`/En elaboración, incluidas las de los puestos 11–30; ya no requieren pulsar Preparar. Procesa los `preparing`/`update` del más antiguo al más reciente y reintenta después las `problematic` que sigan en el Top 30. Conserva cierres del usuario, explicaciones vigentes y revisiones; una explicación caducada de más de 48 horas abre un episodio con ID independiente según el aplicador. No selecciones rangos 31+ ni «Próximas tendencias». Una captura sin respaldo actual no autoriza a encolar tendencias históricas. Capturar y encolar no equivalen a ejecutar investigación ni a persistir una explicación. No invocar ImageGen en esta pasada.

## Ejecución directa desde el chat (incluido el PC)

Cuando el usuario envía «Ejecuta TTendencias» a una conversación de ChatGPT, es una orden de realizar **en esa misma conversación** la pasada editorial real sobre `main`, conforme a este contrato. No se satisface la orden actualizando únicamente `control/ttendencias-run-trigger` ni escribiendo `trends/run-now-trigger.json`: un commit en el PR #7 **no inicia ningún editor por sí mismo**. Esa delegación solo es válida si se ha comprobado que existe un consumidor Work de eventos activo y que la solicitud ha recibido confirmación `RUNNING`. Sin confirmación, informar del bloqueo, no simular que está en curso. Para la ejecución directa, usar el PR #7 exclusivamente como telemetría, ejecutar el ciclo editorial, persistir y releer para verificar las revisiones tratadas. No reactivar programaciones antiguas; respetar siempre `explanation_only`. La generación IA está separada de la pasada editorial: `Ejecuta TTendencias` NO llama directamente a ImageGen ni espera imágenes. **Pero cada tendencia continúa su tramo visual inmediatamente al quedar `explained`, sin esperar al final del lote editorial**: el reparador de Explicadas busca/normaliza imagen de archivo, crea o reintenta su job IA y el bot entrega esa tendencia cuando la IA es válida. La pasada editorial puede seguir con la tendencia siguiente en paralelo. Los checks Gag IA/Imágenes quedan como override manual. La pasada editorial puede conservar/buscar fallback real sin bloquear el texto.

### Telemetría obligatoria de TODA ejecución directa

La ejecución directa —incluida la lanzada por la programación de Windows que escribe «Ejecuta TTendencias»— **debe dejar telemetría aunque procese 0 tendencias**.

1. Antes de investigar, lee los comentarios del PR #7 y localiza el comentario canónico `TTENDENCIAS_RUNTRACE_V1` con `"canonical":true` (actualmente comment_id `5859532515`). Si no existe, créalo una sola vez. Actualiza ESE MISMO comentario a `RUNNING` con un `run_id` nuevo, `source:"chat"`, `started_at`, `updated_at`, `phase:"preparing"`, `current:0`, `total` real y resumen vacío. Nunca crees un comentario RUNTRACE nuevo por cada pasada.
   - En ese mismo arranque actualiza `trends/pending-repair-trigger.json` con `run_id`, `requested_at` y `reason:"execution-start-pending-repair"`. Ese commit despierta el saneamiento visual de Pendientes aunque la cola editorial nueva sea 0. No esperes al cierre para hacerlo.
2. Actualiza ese comentario durante las fases reales `investigating`, `drafting`, `remate_selection`, `persisting`, `verifying` y `closing`. `remate_selection` se usa solo cuando se está evaluando el remate. No uses `image_generating` ni `image_persisting` en una pasada editorial normal: la capa visual se ejecuta asíncronamente después de `explained`, mediante jobs independientes automáticos o un override manual.

#### Telemetría visible de grano fino

El panel de control debe poder contar **qué estás haciendo ahora**, no solo que la ejecución está activa. Por ello, el mismo comentario RUNTRACE se actualiza antes y después de cada paso significativo y siempre contiene `trend_id`, `title`, `current`, `total`, `phase` y un `message` humano, concreto y breve.

Para CADA tendencia/grupo, actualiza el RUNTRACE como mínimo en estos hitos, sin agruparlos en un único salto:
- JIT: `phase:"verifying"`, mensaje «Releyendo estado autoritativo de <nombre>».
- Investigación: `phase:"investigating"`, mensajes que indiquen la acción real: «Buscando detonante actual», «Contrastando fuente 1/2», «Contrastando fuente 2/2», «Hecho esencial verificado» o el motivo concreto por el que no se verifica.
- Redacción: `phase:"drafting"`, mensajes «Redactando explicación factual» y «Comprobando límite de X».
- Remate: si procede, `phase:"remate_selection"` con «Generando candidatos de remate», «Evaluando candidatos con ratings» y «Remate seleccionado»; si se omite, mensaje explícito «Sin remate · explicación factual suficiente».
- Persistencia: `phase:"persisting"`, mensajes separados «Guardando ficha Explicada», «Actualizando requests», «Retirando revisión de la cola».
- Verificación: `phase:"verifying"`, mensajes «Releyendo main», «Verificando id+revision y texto persistido» y finalmente «Tendencia cerrada y verificada».
- Cambio de entrada: antes de empezar la siguiente, incrementa `current` y cambia inmediatamente `trend_id/title`; nunca dejes en pantalla el nombre anterior mientras trabajas otra tendencia.

Si una búsqueda web, escritura GitHub o relectura tarda varios segundos, publica el mensaje **antes** de ejecutarla. Si una operación devuelve un resultado material, actualiza de nuevo el mensaje al terminar. No inventes actividad: el mensaje describe exactamente la operación real que acaba de empezar o terminar.
Además conserva en RUNTRACE `activity` como una lista cronológica de los **últimos 20 hitos** de esta ejecución. Cada hito es `{at,phase,trend_id,title,message}` y se añade al mismo tiempo que se cambia `message`; no borres los hitos anteriores salvo para limitar la lista a 20. Incluye `activity` también dentro de `last_run` al persistir `trends/editorial-runtime.json`.
3. Al terminar, incluso con cola vacía o con 0 explicaciones cerradas, cierra el mismo RUNTRACE como `DONE` (o `DONE_WITH_INCIDENTS` si hubo incidencias no globales; `ERROR` solo ante fallo global), con `finished_at`, `updated_at` y `summary` real.
   - `summary.visual_backlog` se mantiene por compatibilidad y debe ser `0` en una ejecución editorial normal. Las imágenes manuales tienen lifecycle independiente y nunca provocan una pasada editorial automática de seguimiento.
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
   **Persistencia atómica obligatoria:** para una revisión nueva o reexplicada, escribe primero/además la ficha vigente en `trends/telegram-manual-explained.json` con el MISMO `id`, `revision`, `explanation`, `closer_text` y `explained_at`. No basta con actualizar `requests.json`. Tras ambos commits, relee `main` y compara exactamente esos cinco campos. Si falta la ficha o difieren, la entrada NO puede contarse como cerrada ni retirarse silenciosamente de la cola; corrige la persistencia en la misma pasada y registra incidencia si no es posible.
3. solo entonces se retiran esas mismas revisiones de `trends/editorial-queue.json`;
4. relee los tres archivos desde `main` y exige consistencia antes de contar el item como cerrado.

Si una escritura intermedia falla, relee SHA y reintenta; no redactes de nuevo una explicación ya persistida. Antes de empezar trabajo nuevo y otra vez al cierre, reconcilia idempotentemente cualquier explicación `explained` ya persistida con su revisión exacta en requests/cola. Nunca uses solo el nombre para reconciliar revisiones.


## Norma prioritaria: remate obligatorio en tendencias políticas

Para toda tendencia cuya categoría editorial o hecho principal sea político (elecciones, partidos, dirigentes, parlamentos, decisiones gubernamentales o declaraciones políticas), la explicación **NO se cierra ni entrega como `explained` sin exactamente un remate `🌶️`** original, concreto, satírico y políticamente neutral. Es humor sobre el hecho, los trámites, los tiempos y contradicciones verificadas, nunca una consigna electoral, afirmación inventada ni burla de víctimas. Explora hasta cinco candidatos, contrasta con las valoraciones y reduce el texto factual sin perder datos esenciales para que el tuit completo tenga menos de 280 caracteres. Si no consigues ninguno seguro y digno de publicarse, mantén la revisión pendiente de redacción, con indicación `closer_missing` y aviso de revisión, sin enviarla como completada; continúa con las demás tendencias. Las tragedias o riesgos para víctimas mantienen la protección editorial aunque impliquen actores políticos. No conviertas esto en una búsqueda indefinida ni inventes un chiste de relleno.

## Saneamiento del remate de Explicadas recientes

En cada pasada editorial, además de la cola, revisa las fichas `explained` recientes (últimas 24 horas) que aún tengan `closer_text` vacío. No omitas la búsqueda del remate por la mera categoría `Política`: elige, si es posible, un único remate satírico sobre circunstancias verificadas, imparcial, sin consignas ni hechos inventados. Excluye tragedias, sufrimiento y víctimas cuando el humor sea inapropiado. Si hay remate adecuado y el tuit final cabe en el límite de X, completa **la misma revisión** en el registro de Explicadas y en requests, actualizando `explanation` y `closer_text` sin duplicar la línea `🌶️`; conserva identificadores y fecha de explicación y evita crear otra tarjeta Telegram. Si no lo hay y el tema es político, conserva la revisión abierta hasta redactar un remate seguro; para temas no políticos, conserva la explicación factual y registra falta de remate sin bloquear otras tareas. No basta con añadir la línea solo a `closer_text`: `explanation` debe contener el tuit completo una sola vez.

## Saneamiento obligatorio de Pendientes al iniciar cada ejecución

Antes de dar por terminada una ejecución —y preferiblemente al principio, para que la reparación visual pueda avanzar mientras investigas entradas nuevas— revisa también **todas las tarjetas que sigan realmente en Pendientes y cuya explicación tenga menos de 24 horas**. Las de 24 horas o más quedan fuera del saneamiento automático y no se intentan reparar ni enviar. La fuente autoritativa es la vista reconciliada de `trends/telegram-manual-explained.json` + `trends/requests.json`, excluyendo revisiones `grouped`, las archivadas/copied en `trends/explained-copy-state.json` y las que tengan `telegram_package_status:"published"|"dismissed"`.

Para cada Pendiente vigente con `explained_at` < 24 h:
1. **Explicación**: no la reinvestigues ni la reescribas solo para reparar campos accesorios.
2. **Remate**: si `closer_text` está vacío, intenta generar/seleccionar un único remate breve usando exclusivamente la explicación factual ya verificada y los ratings disponibles. Solo persístelo si mejora el texto y el paquete completo sigue <=280 caracteres. Si ninguno sirve, deja `closer_text` vacío: el remate es opcional y nunca bloquea.
3. **Imagen de archivo**: si falta o la URL guardada ya no es un raster válido, deja que el reparador visual vuelva a buscarla en las fuentes verificadas. Un fallo de archivo no bloquea IA ni Telegram.
4. **Imagen IA**: si falta, falla o no supera la validación física vigente, debe existir un job automático de reparación. Si ya hay una IA válida para la revisión actual, no regeneres.
5. **Telegram**: si al finalizar el ciclo del item existe explicación + IA válida, intenta entregar inmediatamente ese item; añade archivo si existe. No esperes al final del lote ni a que otras tendencias estén completas.

Cuando repares un remate, sincroniza el mismo `closer_text` en la ficha vigente de `trends/telegram-manual-explained.json` y en la revisión exacta correspondiente de `trends/requests.json`, sin cambiar `explanation`, `explained_at`, `id` ni `revision`. Haz la reparación en lote cuando sea posible para reducir escrituras.

La telemetría debe contar este saneamiento: mensajes como «Revisando Pendientes · 12 tarjetas», «Pendiente 3/12 · falta remate», «Pendiente 3/12 · reparación visual solicitada» o «Pendiente 3/12 · paquete ya completo». Este saneamiento forma parte de una ejecución normal incluso si la cola nueva está vacía.

## Ámbito y estado

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTendencias y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa para investigar por qué una tendencia es tendencia AHORA y verificar hechos actuales. La pasada editorial NO genera directamente imágenes IA. Puede conservar una imagen de archivo/fallback verificable; **en cuanto cada tendencia queda `explained`**, el reparador automático crea o reintenta su Gag IA sin esperar a que terminen las demás. Cada tendencia tiene ciclo visual independiente y puede llegar a Telegram mientras la pasada editorial continúa.

Telegram NO es canal de control editorial: el modo web sigue siendo autoritativo. El bot de TTendencias se usa únicamente como canal adicional para entregar paquetes visuales y recibir las acciones Publicado/Desestimar de esos paquetes. No proceses TTiTTulares ni SeLoRecordamos. **Aislamiento de salida obligatorio:** TTendencias no envía noticias, candidatos, eventos ni estados a TTiTTulares; cualquier instrucción histórica de “puente a TTiTTulares” queda anulada. **Esto NO elimina Próximas tendencias:** `trends/update_trends.py` puede seguir leyendo la cobertura de TTiTTulares como señal de entrada para anticipar tendencias. Lo prohibido es escribir o enviar desde TTendencias hacia TTiTTulares. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Formato vigente de explicaciones para un tuit (prioridad de redacción)


### Categoría editorial compacta para Pendientes

Cada explicación/grupo cerrado debe persistir también un campo `category` con **una sola etiqueta breve** que permita decidir de un vistazo si merece imagen IA. Usa preferentemente esta taxonomía estable: `Deportes`, `Política`, `Espectáculos`, `Música`, `TV`, `Guerra`, `Atentado`, `Desastre`, `Sucesos`, `Justicia`, `Economía`, `Tecnología`, `Cultura`, `Sociedad`, `Salud`, `Internacional`, `Motor`, `Viral/Redes`, `Otros`.
- Elige por el **hecho explicado**, no por el nombre de la tendencia.
- `Guerra`, `Atentado` y `Desastre` tienen prioridad sobre categorías genéricas como Política o Internacional cuando describen el hecho central. Estas categorías no bloquean por sí mismas la generación IA.
- En agrupaciones, la categoría corresponde al acontecimiento compartido.
- Persiste el mismo `category` en la ficha vigente de `trends/telegram-manual-explained.json` y en las revisiones cerradas de `trends/requests.json`.

Cuando `trends/editorial-config.json.editorial.mode` sea `explanation_only` (o `explanation_only:true`), esta sección prevalece sobre cualquier formato heredado de Principal/A/B/C. **No cambia el flujo, la verificación factual, los estados, la agrupación ni la persistencia propia de TTendencias. No existe ya ningún puente editorial hacia TTiTTulares: no crees, actualices ni envíes candidatos/noticias a `ttittulares/trend-candidates.json` ni a ninguna cola de TTiTTulares.** En este modo se redacta UNA explicación por acontecimiento/grupo, sin alternativas. La pasada editorial puede mantener la búsqueda de foto web/fallback, pero NO llama a ImageGen; tras persistir `explained`, el reparador visual automático continúa el pipeline. El panel conserva el Gag IA manual como override.

**Regla de salida no bloqueante para tendencias NO políticas:** El chascarrillo es deseable, pero no es requisito para cerrar una tendencia no política cuya explicación factual ya esté verificada. **EXCEPCIÓN PRIORITARIA: tendencias políticas: el remate es obligatorio para completar/entregar `explained`; si falta, mantener revisión editorial conforme a la norma anterior.** Genera internamente hasta CINCO candidatos breves de remate concreto y adecuado y somételos a la selección basada en ratings descrita más abajo; solo el ganador puede hacerse visible. Si ninguno sirve, resulta inapropiado por sensibilidad, falla su generación o no cabe en el tuit, persiste inmediatamente la explicación factual completa con `closer_text:""`, sin línea `🌶️`, sin estrellas y con estado editorial normal `explained`. No reintentes indefinidamente, no esperes otra generación, no bloquees la cola ni las siguientes tendencias y NUNCA marques `problematic`, `preparing` o `update` exclusivamente por falta de remate. La verificación factual y el límite del tuit siguen siendo obligatorios; si no se verifica el hecho, aplica el tratamiento normal de hechos no verificados. Registra una incidencia editorial no bloqueante cuando falte el remate por un fallo de generación, no cuando su omisión sea deliberada por sensibilidad. La línea de dos o tres hashtags se exige en cada nueva explicación; la última línea `🌶️` solo se exige CUANDO EXISTA un remate válido.

- **Cabecera y sintaxis OBLIGATORIAS:** la cadena completa `explanation` comienza EXACTAMENTE con `TT#N <nombre literal de la tendencia> es tendencia por <motivo>` o `TT#N <nombre literal de la tendencia> es tendencia porque <motivo>`, donde `N` es el puesto numérico ACTUAL: usa `rank` actualizado desde `trends/recent.json` para Top 10 y el mejor puesto observado (`anticipated_best_rank`/rank) para tendencias anticipadas. Ejemplos estructurales: `TT#4 #LaHora28S es tendencia porque ...` y `TT#11 Gobierno de Ceuta es tendencia por ...`. Conserva exactamente el nombre de la tendencia; no uses `Tn`, `Rn`, iconos ni otra cabecera ANTES de `TT#N`. Una tendencia agrupada se redacta para su líder con su propio puesto y nombre; las relacionadas figuran en metadatos, no cambian este inicio. El campo `explanation` almacena el tuit ya completo: el botón Copiar debe usarlo literalmente sin anteponer una segunda cabecera.
- **Orden final obligatorio en las nuevas tarjetas:** primera línea `TT#N <nombre literal> es tendencia por/porque <motivo factual>.`, segunda línea real con `#PalabraClave1 #PalabraClave2` y, opcionalmente, `#PalabraClave3`; tercera y **última línea**, cuando exista, `🌶️ <frase única de remate>`, sin texto posterior. El campo `explanation` guarda el tuit COMPLETO con los saltos reales y el campo `closer_text` guarda solo el remate exacto con `🌶️ `, jamás hashtags. Si no corresponde remate, el tuit termina con la línea de hashtags y `closer_text:""`. El botón Copiar reproduce `explanation` literalmente sin cabeceras adicionales. El control «Puntúa el remate» con 1–5 estrellas permanece FUERA del tuit y se vincula al remate y revisión exactos. La suma del prefijo, hecho, hashtags, saltos, emoji y remate debe permanecer **por debajo de 280 caracteres ponderados para X**. Recorta solo redundancias, no datos esenciales ni la guindilla.
- **Límite estricto:** texto completo **inferior a 280 caracteres ponderados por X** (máximo 279), incluyendo `TT#N`, nombre, ` es tendencia por/porque `, explicación y remate opcional. Reescribe antes de guardar si no cabe; no trunques ni suprimas un dato esencial para forzar el límite.
- La explicación ha de ser **directamente copiable como un solo tuit** de X: límite estricto de **279 caracteres ponderados para el texto FINAL completo**, no solo para `explanation` aislada. Cuenta también el prefijo `TT#N`, el nombre, espacios, puntuación, salto de línea real y remate; no agregues icono ni el formato legado `Tn/Rn`. No añadas URL de fuentes al texto salvo que se cuente correctamente su longitud de X. Reserva preferentemente margen y apunta a 230–250 caracteres finales cuando se pueda.
- Empieza por el detonante verificable **actual**, con quién/qué ocurrió y el contexto imprescindible, sin relleno ni especulaciones. Redacta con brevedad periodística (normalmente una o dos frases factuales).
- **Intenta terminar TODAS las explicaciones con un chascarrillo breve, agudo y específico de ESA tendencia. Cuando haya remate, debe ser SIEMPRE UNA SOLA FRASE autocontenida, con UNA única idea humorística y un golpe final claro**, después del dato factual y sin explicación posterior: humor de monologuista, ironía, sarcasmo o giro ingenioso basado en la peculiaridad real del hecho. Preferir una imagen verbal concreta y mordaz, no un aforismo, moraleja ni un juego de palabras genérico. **Prohibidas las estructuras típicas de dos mitades contrapuestas** (por ejemplo «X tiene A; Y aún busca B», «Una cosa es X y otra Y», o dos sentencias coordinadas que componen una falsa punchline), incluso si caben gramaticalmente en una línea. Positivo de estilo, NO reutilizable: «Le recetó una vaselina que no se vende en farmacias». Negativo de estilo, NO reproducir: «El caso tiene puerta; el decreto aún busca llave». No sacrifiques hechos verificados ni atribuyas intenciones sin evidencia para encajar el chiste; si no sale un remate de ese formato respetuoso y realmente ligado al hecho, omitirlo antes que forzarlo.
- Política/controversias: **remate obligatorio, exactamente uno**, antes de cerrar como `explained` (salvo caso sensible en que debe prevalecer la protección de víctimas y quedar en revisión). Hechos neutrales y atribución de afirmaciones disputadas; la sátira versa sobre circunstancias concretas, no es una consigna partidista. **La política NO es motivo para excluir ImageGen:** una tendencia política con `with_image:true` es elegible para gag IA igual que las demás y puede ser especialmente buena candidata visual. No establezcas flags editoriales de bloqueo de ImageGen por política ni por ninguna otra categoría editorial. No hagas humor de víctimas, tragedias, sufrimiento, abusos ni colectivos vulnerables. Si un remate no resulta respetuoso o distorsiona los hechos, termina sin chiste: **«intenta» no autoriza forzarlo**.
- **Validación obligatoria justo antes de persistir**: construye exactamente el texto que el botón Copiar compartirá (incluido cualquier prefijo que añada la app) y mide su longitud con el contador ponderado de X/twitter-text si está disponible. Si no lo está, usa un margen conservador de hasta 250 puntos de código Unicode para el texto final, evita URLs y trata emojis compuestos como caracteres adicionales. Si alcanza 280 o hay duda, reescribe y vuelve a contar; no cortes a ciegas al carácter 279 ni publiques una explicación incompleta. Si la app añade un encabezado dinámico, descuenta su longitud del presupuesto de `explanation`.
- Ejemplo de tono (solo ilustrativo, no reutilizable): «El programa amplía su emisión hasta las 14:00. La actualidad ya está echando horas extra». No uses el mismo remate en otras tendencias.

### Público/Tremending: título corto y rango no inventado

Cuando `tremending_origin:true`, esta entrada no es una tendencia clasificada por el radar: NO inventes `TT#0` ni pegues el titular completo de Público en el campo `name`. Usa el `name` corto recibido (o acórtalo todavía más, sin perder el acontecimiento) y comienza el tuit completo por `TT 🗯️ <nombre corto> es tendencia por/porque <hecho comprobado>` (prefijo literal `TT 🗯️ ` solo para entradas Tremending, una sola vez). Añade a continuación una línea con dos (o tres) hashtags específicos del hecho y, si procede, un salto de línea con `🌶️ <único remate de una frase>` como cierre. NO agregues otro encabezado de título antes de esa frase ni dentro de la explicación: se muestra y se copia una sola vez. `closer_text` contiene el remate exacto con 🌶️ o queda vacío cuando no procede. Conserva en la ficha `tremending_origin`, `tremending_id`, `article_title`, `source_url`, `selected_tweet`, `selected_tweet_image` y `verification_sources`. El tuit seleccionado es contexto/opinión de su autor, no fuente para afirmar hechos.

**Tremending NO usa ImageGen.** Si `tremending_origin:true`, no llames a ImageGen y no crees `ai_image`. Usa exclusivamente la captura real del tuit seleccionado como `image`/`fallback_image` cuando esté disponible; si la captura aún está pendiente, conserva `image_status:"pending_capture"` sin bloquear el texto.

### Imagen IA: reparación automática posterior

La elaboración editorial **NO llama a ImageGen** y no espera imágenes. Su responsabilidad termina cuando la explicación queda verificada y persistida como `explained`.

Para toda tendencia normal ya explicada:
- conserva `with_image:true`: significa **apta para la capa visual posterior**;
- no pongas `with_image:false` para ahorrar imágenes, por categoría, por falta de fallback o por decisión editorial automática;
- no marques política como bloqueo;
- `safety_sensitive_weather` por sí solo tampoco bloquea: lluvia, temporal, inundación, calor, nieve u otros fenómenos meteorológicos pueden ser objeto de gag si el hecho no gira alrededor de víctimas;
- **No bloquees ImageGen por sensibilidad editorial.** Muertos, duelo, víctimas, violencia, abuso, menores, desapariciones, guerra, ataques, desastres y otros asuntos sensibles siguen siendo elegibles para la capa visual automática. El texto y el prompt deben permanecer estrictamente factuales y respetuosos; si el generador rechaza una imagen por sus propias políticas técnicas/de seguridad, registra el fallo visual sin reabrir ni modificar la explicación.

Tremending sigue fuera de ImageGen: usa la captura real del tuit seleccionado.

El flujo oficial es:
`preparing/update → explained → reparación de archivo + IA → bot TTendencias`.

El reparador de Explicadas revalida `id + revision`, genera o regenera IA ausente/incorrecta y conserva el job manual del panel únicamente como override. Por tanto, una pasada de explicación **nunca** debe esperar a ImageGen ni mantener abierta la cola por la imagen.

### Paquete visual oficial en el bot TTendencias

Una tendencia puede quedar `explained` sin imagen. La capa visual es posterior y no bloqueante, pero el bot **solo entrega un paquete cuando existe una IA válida** (`chat-imagegen`, `origin:"executing_chat"`, raster limpio, mínimo 1024×576 y SHA256 materializado).

Para cada explicación elegible:
- intenta conservar/recuperar una imagen real como `archive_image` o `fallback_image`;
- si existe imagen de archivo, el bot la envía como foto separada;
- la imagen IA se envía como foto principal con el texto exacto de la explicación;
- el teclado del paquete IA contiene **🖼️ Copiar imagen IA**, **🗂️ Copiar imagen archivo** cuando exista, **📋 Copiar texto**, **✍️ Abrir en X**, **🗑️ Desestimar** y **✅ Publicado**;
- `Publicado` y `Desestimar` actualizan `trends/telegram-image-deliveries.json` y la ficha vigente de `trends/telegram-manual-explained.json`, y borran del bot tanto el mensaje IA como el de archivo;
- una IA ausente, inválida o de una revisión sustituida se vuelve a intentar automáticamente mediante `.github/workflows/repair-ttendencias-explicadas.yml`;
- no dupliques paquetes ya entregados para el mismo `id + revision + ai_sha256`;
- Tremending queda fuera de este paquete IA y mantiene su tratamiento específico. Los flags editoriales legacy de bloqueo de IA no excluyen una tendencia normal.

El bot es un canal adicional de revisión/publicación; el panel web y GitHub continúan siendo el estado autoritativo.

### Contexto para el job de imagen

Todo job de imagen —creado automáticamente por el reparador o manualmente desde **Imágenes**— congela un `context_snapshot` con, como mínimo:
- `name`, `id` y `revision`;
- `explanation` factual ya verificada;
- `closer_text`/remate exacto;
- contexto de grupo/rango y fuentes de verificación cuando estén disponibles.

Ese snapshot es la fuente autoritativa para el gag. El chat de imagen no reescribe ni reinvestiga la explicación: primero decide internamente cuál es el único gag central y después lo convierte en una escena clara y bien acabada. La variedad está en el estilo asignado; la coherencia está en el criterio de una sola idea fuerte, sin barroquismo ni ilustración literal.

Política puede usar sátira situacional basada en los hechos del snapshot, sin inventar acusaciones, propaganda, llamadas al voto ni presentar juicios partidistas como hechos. No se hace humor de víctimas, duelo, abuso o sufrimiento humano.

La imagen es una capa separada y no bloqueante. Ningún estado de ImageGen cambia una explicación a `problematic`, `preparing` o `update`.

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

## Regla de cola autoritativa y separación visual

`trends/editorial-queue.json` es autoritativo para decidir si existe trabajo. Si contiene al menos un item cuya revisión vigente está `preparing` o `update`, está PROHIBIDO cerrar una pasada como 0/0 o «sin trabajo editorial». Deben procesarse primero TODOS esos items, del más antiguo al más reciente, salvo que la barrera JIT confirme que esa revisión ya dejó de estar activa.

Una ejecución normal `Ejecuta TTendencias` NO llama directamente a ImageGen, NO crea `trends/image-outbox/**` y NO espera imágenes. Tras materializar `explained`, el reparador automático de Explicadas crea/reintenta los jobs IA; el panel conserva jobs manuales como override.

## Estado inicial y watchdog

1. Lee SIEMPRE `trends/editorial-queue.json` desde `main`.
2. Lee `trends/recent.json` y `trends/editorial-config.json`.
3. Si `trends/recent.json.captured_at` supera 20 minutos, actualiza `trends/refresh-trigger.txt` en `main` para pedir una captura fresca y después relee `trends/editorial-queue.json`, `trends/recent.json` y `trends/editorial-config.json`.
4. Antes de considerar la pasada vacía, relee `trends/editorial-queue.json` y `trends/requests.json`. Si existe cualquier revisión activa `preparing` o `update`, la pasada NO está vacía. Las solicitudes de imagen no forman parte de esta ejecución editorial.
5. Si hay pendientes, usa DOS fases de prioridad: primero TODOS los `preparing`/`update` del más antiguo al más reciente; solo después reintenta los `problematic` que sigan en Top 30. Un problematic antiguo NUNCA puede hacer starvation de tendencias nuevas.
6. PROCESAMIENTO EDITORIAL SECUENCIAL: para cada tendencia/grupo investiga → redacta/verifica → persiste y cierra el TEXTO → confirma requests/cola. NO registres intentos visuales, NO llames a ImageGen y NO generes `trends/image-outbox/**` durante esta pasada. La imagen IA se gestiona después de `explained` mediante el reparador automático y, opcionalmente, overrides manuales.
7. Una tendencia `problematic` se reintenta automáticamente mientras siga en el Top 30, pero siempre al final de la pasada. Si ya salió del Top 30, no se fuerza otro intento.
8. Un fallo de un item no debe bloquear los siguientes: registra ese item pendiente/problematic según corresponda y continúa con el siguiente.
9. Relee estado fresco antes de cada escritura. Ante conflicto, relee SHA y reintenta de forma segura.

### Barrera JIT obligatoria por entrada

El lote inicial y los grupos son solo candidatos. **Justo antes de tratar CADA tendencia/revisión** —antes de investigación web, drafting, selección de remate o persistencia editorial— relee desde `main` `trends/editorial-queue.json`, `trends/requests.json` y, cuando corresponda, `trends/telegram-manual-explained.json`. Valida por `(id, revision)`; no uses solo el nombre ni el snapshot inicial para decidir si sigue pendiente.

Si la revisión ya está `explained`, publicada/desestimada por la acción equivalente del panel, ya no aparece como trabajo activo en la cola, o existe una revisión posterior que la sustituye, **sáltala inmediatamente y continúa con la siguiente**. No investigues, no redactes, no selecciones remate, no generes imagen y no la cuentes como tratada ni como incidencia. Si era miembro de un grupo, elimina de la ejecución solo ese miembro y vuelve a evaluar los miembros restantes; si no queda ninguno, salta el grupo completo. La misma barrera se repite justo antes de cualquier solicitud visual de Rehacer. Una acción del usuario en el panel durante una ejecución prevalece siempre sobre el lote/grupo calculado al comienzo.

## Agrupación

Agrupa ANTES de investigar y redactar cuando sea inequívoco que varios términos describen el MISMO acontecimiento real, emisión concreta o episodio del mismo día. La `revision` es propia de cada tendencia y NO impide agrupar revisiones distintas: conserva para cada miembro su `(id, revision)` original y enlázalos a un único `group_id` determinista por hecho/episodio/fecha. Nunca juntes ediciones distintas de un reality ni temas diferentes por compartir lote o programa.

Usa como pistas `batch_id`, `requested_together`, `captured_with`, nombres, contexto y web. Detecta la pertenencia semántica a la MISMA emisión: p. ej., `#LaIslaDeLasTentaciones7`, Kico, Juanpi, Gema, Rubén, Irini, Paola, Sandra y Nacho si el detonante comprobado de TODOS es la misma segunda hoguera y su episodio; deben formar UNA explicación y UNA tarjeta, jamás nueve textos separados. Cuando coincidan, el líder es la etiqueta de la emisión (o el de mejor rank; en empate el más antiguo). Genera UN SOLO registro de explicación del grupo, con `group_id`, `group_title`, `trend_names` y `trend_context` ordenados por rank. Marca como explicada CADA revisión miembro de `trends/requests.json` con el mismo `explanation_group_id`, sin crear registros individuales en `trends/telegram-manual-explained.json`. Solo retira cada miembro de la cola tras verificar grupo y request en main. NO hagas ningún puente a TTiTTulares, ni por grupo ni por tendencia individual; TTendencias termina su flujo dentro de TTendencias. En modo legado, genera UN SOLO outbox del líder y guarda todos los términos cubiertos en `prepared_item.related_trends`.

Si la relación no es inequívoca, no agrupes; verifica primero el detonante concreto de cada término. Si una tendencia ya fue explicada por el mismo episodio (incluida revisión posterior), enlázala al grupo existente cuando corresponda en vez de crear otra tarjeta. Solo genera nueva explicación si hay acontecimiento o novedad material posterior, respetando la regla de reexplicación a las 48 h. El prefijo `TT#N <nombre líder>` se guarda UNA sola vez dentro de `explanation` y la UI lo muestra una sola vez, jamás como encabezado duplicado.

## Contexto aportado por el usuario

Si un item trae `rewrite_instruction`, trátalo como CONTEXTO APORTADO POR EL USUARIO para explicar por qué la tendencia está activa. Debes leerlo antes de investigar y usarlo como pista prioritaria para orientar las búsquedas y la reelaboración. No lo ignores ni lo sustituyas por la explicación anterior problemática. Verifica con fuentes actuales todo dato factual verificable antes de publicarlo; si el texto del usuario contiene una interpretación u opinión, úsala como contexto editorial sin presentarla como hecho no comprobado.
**TTActualidad / Aportar pistas (obligatorio):** si la solicitud incluye `user_pistas` y `hints_verification_status:"unverified"`, la entrada es una NUEVA investigación de la revisión exacta `id+revision`, aunque haya abandonado el Top 30. Conserva las pistas en `trends/requests.json`, úsalas solamente como hipótesis y posibles enlaces para localizar fuentes independientes y comprobar fechas y hechos. No conviertas una pista en afirmación verificable por el simple hecho de que la aporte el editor. Si la comprobación falla, conserva `user_pistas` e `investigation_history`, registra `problem_reason` claramente y no publiques explicación ni remate falsamente concluyentes. Si funciona, escribe el texto factual completo y un remate nuevo según las reglas editoriales vigentes. El reencolado usa únicamente la cola habitual `trends/editorial-queue.json`, sin canal ni transporte alternativo.


## Recuperación de Reexplicar desde la app

Al comenzar cada pasada revisa también las Explicadas recientes con `rewrite_pending:true`. Esa marca es autoritativa aunque `trends/requests.json` o `trends/editorial-queue.json` hayan sufrido una carrera. Para cada una:
- crea o repara la request `status:"update"` con una revisión estrictamente mayor que la última explicada;
- usa `rewrite_instruction` guardada como hipótesis/contexto aportado por el usuario;
- vuelve a investigar desde cero el motivo actual de la tendencia, contrasta ese contexto con fuentes actuales y reescribe la explicación factual; genera un remate nuevo solo si procede;
- Reexplicar es exclusivamente editorial: no llama a ImageGen ni dispara imágenes;
- la nueva revisión normal queda con `with_image:true` para que vuelva a entrar en la reparación visual automática de Explicadas; el panel conserva la selección manual como override. Tremending conserva su captura real y sigue sin usar ImageGen;
- al materializar la nueva revisión, elimina `rewrite_pending` de la revisión anterior;
- si la nueva revisión queda terminalmente fallida, conserva una razón explícita y limpia igualmente la marca para no crear un bucle.

Nunca descartes un `rewrite_pending:true` porque la cola textual esté vacía.

## Investigación y verificación

Para cada grupo/item usa todos los campos relevantes: `id,name,rank,status,requested_at,revision,rewrite_instruction,batch_id,requested_together,captured_with,anticipated,anticipated_at,anticipated_best_rank,anticipated_social_source_count,anticipated_news_source_count,anticipated_news_title,anticipated_entered_top10_at`.

Investiga por qué es tendencia AHORA en España con búsquedas web actuales y fuentes fiables.

- Política/controversia: factual y neutral.
- Deportes: confirma expresamente el estado/resultado justo antes de redactar. Nunca presentes como final algo que siga en curso o cuyo resultado no hayas confirmado.
- Si el item llega como `problematic`, trata la ejecución como un NUEVO intento: cambia las consultas y usa el contexto acumulado, no te limites a repetir exactamente las búsquedas anteriores.
- Si tras DOS búsquedas distintas no puedes determinar el detonante con suficiente fiabilidad, escribe `trends/editorial-outbox/<id>-r<revision>.json` con `id,name,revision,status:"problematic"` y un `problem_reason` concreto. Continúa con los demás. Ese estado NO elimina la tendencia del Top 30: mientras siga allí, el radar la mantendrá visible y volverá a incluirla para otro intento en una ejecución posterior.
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

## Imagen IA — contrato automático posterior

Este bloque sustituye cualquier regla histórica que ordene generar imágenes dentro de `explanation_only` o que limite la generación a una acción manual.

En `explanation_only`:
1. investiga, verifica y persiste el texto;
2. deja toda tendencia normal con `with_image:true`; la sensibilidad editorial no crea un bloqueo de IA. Tremending conserva su flujo específico de captura real;
3. **no llames directamente a ImageGen**;
4. **no esperes una imagen**;
5. continúa inmediatamente con la siguiente entrada.

Después de persistir `explained`, `.github/workflows/repair-ttendencias-explicadas.yml` revalida la revisión, busca/normaliza imagen de archivo y crea/reintenta el job IA si falta o es inválido. El check **Gag IA** + atajo **Imágenes** se conserva como override manual.

### Contrato visual del job dedicado

**NORMA VISUAL PRIORITARIA 16/10/2026 — GUINDILLA SOLO EN TEXTO:** `🌶️` marca únicamente el remate escrito (`closer_text` y explicación), nunca el contenido gráfico. **Ninguna imagen de TTendencias debe incluir guindillas, chiles, pimientos picantes, el emoji, sus siluetas, iconos, logos, mascotas, firmas ni decoraciones equivalentes.** El gag representa el significado del remate, NO su marcador. Rige para el bridge local, jobs automáticos, pedidos manuales, regeneraciones e ilustraciones serias. Se preserva exactamente el remate textual con `🌶️`; si la imagen contiene una guindilla, se descarta y se regenera sin reabrir la explicación.


Para cada job automático o manual:
- genera UNA sola imagen para ese `target_id + revision`;
- usa exclusivamente el `context_snapshot` del job;
- **principio fijo: más gag, menos barroquismo**: una sola idea visual fuerte, lectura en 1–2 segundos, pocos elementos protagonistas y fondo solo si refuerza el chiste;
- el acabado debe ser cuidado, expresivo y bien resuelto; simplificar la composición NO significa hacer un dibujo pobre, infantil o esquemático;
- el job asigna `image_style`, `image_style_name` e `image_style_index` desde un banco de estilos variables. **Respeta ese estilo para esta imagen y no lo sustituyas por un acabado fijo de cómic cinematográfico**;
- el banco rota entre caricatura tinta/acuarela, cómic europeo, póster gráfico sofisticado, absurdo semirrealista, stop-motion/clay, retro 60s, grabado moderno, pop art refinado, cartoon 3D y novela gráfica;
- en regeneraciones puede cambiar el estilo para buscar una solución realmente distinta;
- una sola escena narrativa, composición 16:9 y casi sin texto;
- elimina personajes, símbolos, carteles y objetos que no refuercen directamente el gag central;
- evita retrato neutro, collage, split-screen, infografía, interfaz, screenshot e ilustración meramente literal;
- no reutilices rasters, prompts, gags ni elementos de otra tendencia;
- `context_guard={"version":3,"trend_id":"<id>","revision":<revision>,"scope":"current_item_only"}`.

Los asuntos meteorológicos son válidos mientras el hecho no tenga como centro muertes/víctimas/sufrimiento. Los asuntos políticos son válidos con sátira situacional factual y neutral, sin propaganda ni persuasión política.

Las entradas sensibles (muertos, víctimas, duelo, violencia grave, abuso, menores en contexto sensible, desaparición, guerra/ataque con víctimas o sufrimiento comparable) **no se excluyen editorialmente del job IA**. Deben usar contexto factual y tratamiento visual respetuoso. La aceptación o descarte editorial de la imagen corresponde al usuario; un rechazo propio de ImageGen se registra como fallo visual no bloqueante.

El raster resultante se entrega por el puente dedicado y la persistencia directa vigente. Fallar o agotar el tiempo de imagen solo afecta a la capa visual y nunca reabre ni modifica el texto editorial.

## Outbox editorial legado

### Persistencia textual obligatoria

Esta subsección solo aplica al modo legado que todavía use `trends/editorial-outbox/**`. El outbox editorial contiene texto/metadatos; la imagen V3 usa SIEMPRE `trends/image-outbox/**`.

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
- estados/metadatos de imagen pequeños, nunca data URLs V3
- metadatos `anticipated*` cuando existan.

`alternatives[].remate` contiene solo el remate `🌶️ ...`; `tweet_text` contiene el tuit completo una sola vez.

No dupliques un outbox completo existente. Si el mismo outbox/revisión existe pero incumple la estructura, corrige ESE MISMO archivo y no crees una revisión nueva solo para reparar formato o persistencia técnica.

## Aplicación y verificación

El aplicador real es `.github/workflows/ttendencias-editorial-apply.yml`, que ejecuta `trends/apply_editorial_outbox.py` y consume `trends/editorial-outbox/**`.

La creación del outbox NO completa el item.

Después de cada outbox `ready`, comprueba el run asociado cuando sea necesario y relee `trends/editorial-queue.json`, `trends/prepared.json` y el estado de solicitudes consumido por la app.

Un item editorial termina cuando:
1. aparece realmente en el estado de salida que corresponda;
2. el líder y todos los `related_trends` cubiertos ya no aparecen pendientes en la cola.
La imagen puede seguir pendiente o fallar: nunca mantiene abierto el item editorial.

Si el outbox existe pero sigue en cola, trátalo como pendiente de aplicación. Inspecciona los workflows/runs/jobs del aplicador y reintenta de forma idempotente usando exclusivamente el mecanismo GitHub Actions existente. No crees una nueva revisión/outbox para forzar, no montes un flujo paralelo y no despliegues Vercel.

## Verificación final

Al terminar, relee hasta tres veces, cuando sea necesario, la cola, `trends/prepared.json` y el estado consumido por la app.

Para cada item tratado exige consistencia del texto/estado y ausencia de cola. Verifica la imagen por separado, sin usarla como condición de cierre.

Solo considera el item completado cuando todo lo anterior esté verificado. Si persiste un fallo de aplicación, deja constancia técnica y el item pendiente.

La ejecución completa NO puede declararse satisfactoria si cualquiera de los items que intentó tratar sigue en `preparing` o `update` por falta de outbox o aplicación editorial. En ese caso el estado operativo debe quedar como pendiente/waiting o failure según corresponda, nunca como success. Las tendencias `problematic` que sigan en Top 30 son la única excepción: pueden permanecer visibles para un nuevo intento posterior sin convertir el ciclo en fallo.

Nunca uses una rama o PR como sustituto silencioso de `main`.


## Control de originalidad y variedad de remates (prioridad editorial)

Antes de publicar cualquier línea 🌶️, generar internamente hasta cinco enfoques realmente diferentes (ironía, contraste, absurdo, doble sentido, sátira concreta, humor seco). Elegir por especificidad, sorpresa, claridad y rigor, no por facilidad. El remate debe aportar una segunda lectura del hecho verificado, nunca ser una frase genérica que podría acompañar cualquier noticia.

**Antimuletillas:** rechazar «el calendario se ha vestido/salido de gala», «ha tomado nota», «no estaba en el guion», «ha llegado tarde a la fiesta» y variaciones triviales. Evitar repetir en noticias próximas la misma imagen mental, estructura sintáctica o mecanismo humorístico, aunque cambien las palabras. Contrastar, cuando haya registros disponibles, con los últimos 30 remates publicados/explicados del propio proyecto y, si son accesibles, del proyecto hermano. Si hay coincidencia conceptual, regenerar candidatos distintos. No inventar hechos, no hacer chistes sobre víctimas y mantener neutralidad política. Si ningún remate supera este filtro, aplicar las reglas existentes de remate obligatorio/opcional según categoría; nunca rellenar con un cliché.

En la fase `remate_selection` dejar constancia de la evaluación de originalidad y repetición en la telemetría existente, sin alterar formatos de salida ni flujos de Telegram.

