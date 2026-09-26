# TTiTTulares · flujo editorial común

Este archivo es la ÚNICA fuente de verdad para la ejecución editorial de TTiTTulares. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La lógica de activación, horario, anti-solape y telemetría pertenece al envoltorio que invoque este archivo y NO se redefine aquí.

## Ámbito y estado

**ACCESO GITHUB OBLIGATORIO.** Usa el conector GitHub conectado para `fabricelop/europapress-rss`. En ejecuciones programadas el conector puede estar expuesto mediante Code Mode/`functions.exec`; DEBES descubrirlo y usar el mecanismo disponible antes de concluir que GitHub no está accesible. No prohíbas ni evites `functions.exec` si es la vía que expone el conector. No sustituyas una operación GitHub por web pública.

Tu primera operación editorial real debe ser leer desde `main` `ttittulares/editorial-queue.json`. Si hay pendientes, durante ESA MISMA ejecución debes intentar escrituras reales en GitHub conforme al flujo (outbox/aplicación/verificación). No termines con un plan, diagnóstico o resumen sin haber intentado procesar la cola. Si una llamada al conector falla de forma transitoria, redescubre/reintenta con estado fresco antes de abandonar.

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTiTTulares y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa para investigación/verificación actual, para el fallback de imagen de archivo cuando corresponda y para búsqueda de publicaciones públicas de X. La imagen editorial original se genera con el generador de imágenes disponible y se persiste en GitHub.

Telegram NO se usa para entregar noticias ni como parte de la fase editorial. Solo está autorizado como fallback de entrega de una imagen YA GENERADA cuando su integración en la app haya fallado. No proceses TTendencias ni SeLoRecordamos. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Cola y orden de trabajo

1. Lee SIEMPRE `ttittulares/editorial-queue.json`, `ttittulares/status.json`, `telegram/editorial-processing.json` y `telegram/events.json` desde `main`.
2. Al inicio guarda una FOTO de las filas `status:"PROBLEMATIC"` de `telegram/editorial-processing.json`. Esa es la fuente de verdad para los reintentos; los nuevos `PROBLEMATIC` creados durante esta misma pasada se dejan para la SIGUIENTE ejecución.
3. Construye un mapa de `telegram/events.json.events` por `id/event_id`. Para cada noticia usa sus `appearances` como EVIDENCIA MULTIFUENTE estructurada: `source,title,url,first_seen`.
4. Construye al inicio una lista ordenada de trabajo: primero los items de `editorial-queue.json` del más antiguo al más reciente y después las problemáticas de la foto inicial.
5. Si no había cola editorial ni problemáticas iniciales, sigue a la fase 2 si hay noticias READY pendientes de imagen. Solo termina cuando tampoco haya imágenes que procesar.
6. FASE 1 — NOTICIAS, PRIORIDAD ABSOLUTA. Procesa ESTRICTAMENTE todas las noticias editoriales (`PROCESSING` y después las problemáticas iniciales) sin generar, buscar, validar, persistir ni enviar imágenes. Para cada noticia completa verificación, Principal/A/B/C, citas X y outbox `ready`; el `prepared_item` debe entrar en Listas inmediatamente con `image_strategy` decidido, `image_status:"working"` e `image_pending:true` cuando corresponda. La imagen JAMÁS puede bloquear `READY`.
7. Después de CADA outbox editorial fuerza/reintenta el aplicador si hace falta y relee `prepared.json`, `editorial-processing.json`, `editorial-queue.json` y `status.json`. No empieces la fase de imágenes mientras quede una noticia editorial pendiente de esta ejecución.
8. FASE 2 — IMÁGENES, SOLO DESPUÉS DE VACIAR LA FASE EDITORIAL. Relee `prepared.json`/`editorial-queue.json` y procesa secuencialmente los items READY con `image_status` en `working|none|pending|retry` o `image_pending:true`. Para cada uno: construye el brief aislado, genera/valida la imagen, intenta integrarla en la app; si queda accesible marca `image_status:"ready"`/`image_delivery:"app"`. Si existe un raster válido pero no puede integrarse en la app, usa exclusivamente el fallback Telegram de imagen y marca `image_status:"telegram"`/`image_delivery:"telegram"`. Si tampoco puede entregarse, marca `image_status:"none"` conservando la noticia READY. Una imagen fallida nunca devuelve una noticia a En elaboración ni impide procesar la siguiente imagen. Al FINAL de la ejecución no puede quedar ningún item tratado con estado working/pending/retry: debe acabar exactamente en ready, telegram o none.
9. AL COMIENZO de cada ejecución, después de identificar las noticias editoriales pero antes de la fase 2, todos los items READY sin imagen cuyo `image_status` sea `none` vuelven a `image_status:"working"`/`image_pending:true`; así cada ejecución empieza un intento nuevo. Cualquier noticia nueva vuelve a tener prioridad sobre TODOS esos reintentos de imagen. Relee estado/SHA fresco antes de cada escritura; ante conflicto relee y reintenta de forma segura.
10. FASE 3 — AUTOCORRECCIÓN. Relee `ttittulares/execution-errors.json`, agrupa las causas por fase, usa `remediation_prompt` como instrucción de diagnóstico y aplica las correcciones seguras que estén a tu alcance. Registra la acción y su resultado en la telemetría RUNSTATUS. Conserva los errores sin resolver para la siguiente ejecución. Este paso nunca bloquea la siguiente noticia ni altera una publicación lista.

Usa todos los campos disponibles del item activo, incluidos `event_id,title,url,sources,source_count,source_evidence,selected_at,selection_mode,revision,rewrite_request,parent_event_id,update_context,with_image,image_mode,image_instruction`.

Para problemáticas usa además `problem_reason,problematic_at,problematic_attempts,user_validated,user_validated_at`; si `problematic_attempts` falta en un registro antiguo, trátalo como 1.

## Verificación factual

La primera fuente de verificación es la EVIDENCIA MULTIFUENTE YA CAPTURADA por el radar. No obligues a una noticia con varias fuentes coincidentes a superar además dos búsquedas web genéricas.

Para cada item:
1. Localiza su evento en `telegram/events.json` y reúne las `appearances` de fuentes distintas. Si el item ya trae `source_evidence`, úsalo también.
2. Compara el HECHO ESENCIAL, no la literalidad exacta del titular. Corrige mojibake, tildes perdidas, erratas y diferencias normales de redacción al preparar el texto. Una errata como `revisarn vehculos` nunca convierte por sí sola una noticia en problemática.
3. Si al menos DOS fuentes independientes y razonablemente fiables sostienen de forma inequívoca el mismo hecho esencial, considéralo verificado. Con 4 o más fuentes coincidentes, la evidencia interna debe pesar especialmente.
4. Diferencias menores de número redondeado, tiempo verbal, sinónimos o formulación no son contradicción material si el núcleo del hecho coincide.
5. Solo usa búsquedas web adicionales cuando la evidencia interna sea insuficiente, ambigua, antigua o materialmente contradictoria. No hagas búsquedas por cumplir una cuota.
6. Si una fuente principal publica una afirmación y varias apariciones posteriores independientes la confirman, usa el consenso más reciente.
7. Si las fuentes se contradicen MATERIALMENTE sobre el hecho esencial, investiga esa contradicción y redacta solo lo que pueda sostenerse.

- Política/controversia: redacción factual, neutral y atribuida.
- Deportes: confirma expresamente el estado/resultado justo antes de redactar si es un hecho que puede cambiar en tiempo real.
- Un item solo pasa a `problematic` cuando, DESPUÉS de aprovechar la evidencia multifuente y las búsquedas adicionales realmente necesarias, no puede establecerse de forma fiable el hecho esencial o existe una contradicción material sin resolver.
- Para un item de la cola activa que cumpla esa condición, escribe `ttittulares/editorial-outbox/<event_id>-r<revision>.json` con `event_id`, `revision`, `status:"problematic"` y un `problem_reason` concreto. Continúa inmediatamente con los demás items.

## Reintento de problemáticas

Después de terminar TODOS los items de En elaboración, reintenta únicamente las problemáticas que ya existían al COMENZAR esta ejecución.

Para cada una:
1. Si `user_validated=true`, el usuario ha dado expresamente la noticia por válida mediante **Check**. NO vuelvas a exigir verificación factual del titular: prepara directamente el item para Listas usando el titular original, la evidencia multifuente disponible y una redacción limpia/corregida. La validación del usuario no autoriza inventar detalles adicionales que no estén en las fuentes.
2. Si NO está validada por el usuario, vuelve primero a revisar las `appearances` actuales del evento. Muchas problemáticas anteriores proceden de una regla de búsqueda demasiado rígida: si ahora hay al menos dos fuentes independientes que sostienen el hecho esencial, considérala verificada sin exigir dos búsquedas web adicionales.
3. Solo si la evidencia multifuente sigue siendo insuficiente o contradictoria haz un NUEVO intento de búsqueda actual, cambiando las consultas según el `problem_reason`.
4. Si ahora puedes verificar suficientemente el hecho, redacta y escribe un outbox `status:"ready"` normal para la MISMA revisión. El aplicador admite la transición `PROBLEMATIC → READY`.
5. Si vuelve a no poder verificarse suficientemente, NO la devuelvas a `problematic` y NO la dejes bloqueada. Debe pasar a Noticias listas con una versión de respaldo cautelosa.

La versión de respaldo debe:
- conservar SIEMPRE el `title` original completo del item dentro de `prepared_item.title`;
- conservar `url`, fuentes y metadatos originales;
- incluir `prepared_item.fallback_unverified=true`, `fallback_reason` y `original_title`;
- incluir `problematic_attempts_before_ready=2`;
- NO presentar el titular no confirmado como hecho propio;
- redactar Principal atribuyendo lo disponible a la fuente/titular original y dejando claro, cuando sea necesario, que no se ha podido confirmar de forma independiente o que existen datos contradictorios;
- si la investigación encontró una contradicción sólida, mencionarla de forma breve y neutral en vez de repetir el titular como hecho;
- generar A/B/C sobre esa misma base cautelosa. Sus remates pueden ser metaperiodísticos y prudentes (`🌶️ `), sin convertir un dato no verificado en afirmación ni atacar a víctimas;
- mantener cada variante completa ≤280 caracteres;
- buscar imagen y candidatos X solo si pueden relacionarse de forma fiable con el asunto; su ausencia no bloquea el fallback.

El objetivo de este segundo intento es que ninguna noticia quede eternamente en cuarentena: tras dos ejecuciones fallidas sale de Problemáticas y entra en Listas con todo lo útil disponible, pero sin fabricar una confirmación inexistente.

## Redacción

Para cada item verificable genera exactamente cuatro variantes: `Principal`, `A`, `B`, `C`.

- `Principal`: noticia factual; `remate:""`.
- `A/B/C`: el campo `remate` empieza exactamente por `🌶️ `.
- `text` de A/B/C = texto Principal + DOS saltos de línea reales + remate.
- No uses secuencias `\\n` visibles.
- Comprueba expresamente que CADA `text` completo, Principal y A/B/C, mide como máximo 280 caracteres.
- Genera para cada variante una URL `https://twitter.com/intent/tweet?text=` con el texto exacto correctamente codificado.

### Calidad obligatoria de los remates

El objetivo editorial es que cada publicación haga reír SIEMPRE que la noticia lo permita. Cuando el tema no admita humor directo, el remate debe al menos aportar ironía, sarcasmo o una observación que haga pensar. No vale simplemente ampliar la noticia.

A/B/C deben ser TRES mecanismos cómicos o irónicos distintos. Antes de aceptar cada remate, comprueba que cumple TODO esto:

1. Es específico de ESTE acontecimiento, sus protagonistas, la contradicción o la consecuencia concreta.
2. Añade una IDEA NUEVA respecto a la noticia. No parafrasea, resume ni repite el titular.
3. Tiene un giro, contraste, inversión, exageración, analogía inesperada, literalización absurda, doble sentido o sarcasmo reconocible.
4. Evita por completo frases hechas, moralejas genéricas y plantillas intercambiables entre noticias.
5. No usa cierres vagos del tipo «la realidad supera la ficción», «esto se escribe solo», «cosas que pasan», «el tiempo dirá», «queda todo dicho», «circulen», «no hay preguntas», «país de…», ni equivalentes perezosos.
6. No convierte el remate en una segunda entradilla informativa ni en una explicación adicional de lo ocurrido.
7. A/B/C deben atacar ángulos distintos; si dos podrían intercambiarse sin que cambie el chiste, reescribe uno.
8. Al menos UNO de A/B/C debe ser claramente el más afilado/mordaz permitido por el tema.
9. Si al leer solo el remate no se percibe ningún mecanismo humorístico o irónico, RECHÁZALO y reescríbelo.
10. Si los tres remates no superan este control, NO escribas todavía el outbox: reházalos.

En política o asuntos públicos, cualquier ironía debe apoyarse en hechos, declaraciones o contradicciones públicas verificables y no convertir el tuit en una recomendación de voto, apoyo u oposición política.

Nunca hagas humor a costa de víctimas, abusos, tragedias o sufrimiento. En esos casos, si procede, dirige la sátira únicamente a responsables, gestión, instituciones o contradicciones públicas verificadas; si tampoco es apropiado, usa ironía sobria o una observación que haga pensar.

## Imagen · gag generado por defecto y archivo cuando no proceda

Esta sección se ejecuta EXCLUSIVAMENTE en la FASE 2, cuando ya no queda ninguna noticia por pasar a Listas. Si `with_image=true`, aplica exactamente la misma línea visual y el mismo control de calidad de TTendencias, con la única excepción editorial de `archive_sensitive` para noticias en las que el humor visual no proceda.

Los campos `image_mode` e `image_instruction` del item son contexto heredado del selector, NO una orden irrevocable. Reevalúa la estrategia con esta política actual. Si un item antiguo trae `existing_web_image` o “no generes imágenes” pero no cumple los criterios estrictos de `archive_sensitive`, IGNORA esa clasificación heredada y usa `generated_gag`. Una lesión deportiva ordinaria —molestias, retirada por lesión, sobrecarga, esguince u otra lesión no grave ni traumática— NO se considera por sí sola víctima/tragedia/sufrimiento y debe seguir la vía `generated_gag`. Reserva `archive_sensitive` para muerte, lesión grave o traumática, accidente serio, violencia, abuso, catástrofe, sufrimiento humano significativo o situaciones donde el gag pueda trivializar daño real.

### Decisión editorial

- Por defecto genera una imagen editorial ORIGINAL raster PNG/WebP/JPEG con un gag visual específico de ESTA noticia y guarda `prepared_item.image_strategy="generated_gag"`.
- Línea visual aprobada: `editorial-scene-v2-cleveland`.
- La referencia de estilo NO significa flat 2D, pixel-art, vectorial simplificado ni formas geométricas planas. Esas estéticas están expresamente rechazadas para TTiTTulares.
- La prioridad es, en este orden: 1) gag/escena entendible de inmediato; 2) calidad de ilustración editorial; 3) composición con profundidad, iluminación y volumen suficientes; 4) robustez del raster; 5) detalle fino.
- PRIORIDAD DE VELOCIDAD Y ROBUSTEZ: no generes ni persistas resolución innecesaria. Objetivo normal: alrededor de 768 px en el lado largo (por ejemplo 768×512 en paisaje o 768×768 si la escena es cuadrada). No subas de 896 px en el lado largo salvo que la herramienta no permita otra salida. La imagen debe verse perfectamente en móvil/X; se prefiere menos píxeles y un raster ligero antes que detalle fino que ralentice generación, transferencia o aplicación.
- Usa detalle MEDIO, composición limpia y pocos elementos importantes. Para `generated_gag` prefiere JPEG sRGB de calidad aproximada 80–84 (objetivo 82), sin metadatos innecesarios. Si el generador entrega un raster mayor, redúcelo UNA sola vez antes de persistir manteniendo proporción y sin reescalarlo después.

La imagen generada debe ser una sola escena narrativa de caricatura/ilustración editorial:
- protagonista(s) integrados en un entorno;
- acción y expresiones claras;
- profundidad, volumen, iluminación y texturas visibles, sin exigir fotorealismo;
- perspectiva y puesta en escena coherentes;
- gag VISUAL directamente ligado al hecho real;
- el gag debe seguir entendiéndose aunque se elimine todo el texto;
- cero texto siempre que sea posible; si es imprescindible, breve y diegético.

Rechaza y regenera si aparece cualquiera de estos patrones:
- flat 2D, pixel-art, vectorial simplificado, block shapes o paleta plana/limitada como lenguaje dominante;
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
- composición sin profundidad/volumen;
- imagen incompleta, cortada, truncada o parcialmente renderizada;
- grandes zonas negras, transparentes o vacías que no pertenezcan realmente a la escena.

No se exige fotorealismo ni convertir a personas reales en fotografías simuladas: se busca ilustración/caricatura editorial con acabado rico, profundidad y gag, no una imagen plana. Nunca inventes citas ni hechos visuales que atribuyan a una persona algo no verificado. En política/asuntos públicos, el gag debe apoyarse en hechos o contradicciones públicas verificables y mantener neutralidad política.

Si hay muerte, lesión grave o traumática, víctimas de violencia/abuso, tragedia, sufrimiento humano significativo, catástrofe o cualquier noticia en la que un gag cómico pueda trivializar daño real, NO generes humor. Una lesión deportiva ordinaria no activa esta excepción. Guarda `prepared_item.image_strategy="archive_sensitive"` y conserva el mecanismo anterior: imagen EXISTENTE del mismo acontecimiento, priorizando fuente oficial/primaria y después medios fiables. Segunda vía: página original/og:image. Derechos no verificados => `rights_status:"unverified"`.

Un fallo técnico o DE ESTILO del generador NO convierte una noticia apta para gag en `archive_sensitive`. No uses foto de archivo como sustituto técnico del renderer.

### Brief visual aislado obligatorio antes de generar

ANTES de CADA llamada al generador crea desde cero un `visual_brief` autocontenido usando EXCLUSIVAMENTE el item activo. No reutilices prompts, imágenes, personajes, lugares, deportes, expedientes, gags ni contexto visual de ningún item anterior.

El brief debe comenzar literalmente con `EVENTO ACTUAL: <event_id> · <title>` y contener: `HECHO CENTRAL` (una frase factual), `GAG VISUAL` (una sola idea ligada al hecho), `ELEMENTOS OBLIGATORIOS` (2–4), `ELEMENTOS PROHIBIDOS` (contextos secundarios que desvíen la imagen) y `ESCENA` (una composición única y sencilla).

REGLA DE AISLAMIENTO: título, factual_summary, gag elegido y visual_brief del item activo son la ÚNICA memoria semántica permitida para la llamada de imagen. No añadas por asociación otros casos conocidos del protagonista. Si el hecho es «jubilación por edad», la imagen debe visualizar edad/jubilación/calendario/BOE según el gag elegido; no puede sustituir el tema por otros procedimientos judiciales del protagonista.

Antes de generar, preflight obligatorio: (1) gag = HECHO CENTRAL; (2) obligatorios presentes; (3) prohibidos excluidos; (4) el prompt NO podría servir igual para otra noticia del mismo protagonista. Si falla, reescribe el brief antes de generar.

En `IMAGE_RETRY`, reconstruye un visual_brief fresco desde `prepared_item.event_id,title,factual_summary,variants`; nunca uses por sí sola la instrucción genérica de la cola.

### Control del raster generado

DESPUÉS DE GENERAR, inspecciona la imagen REAL, no solo el prompt. Compárala expresamente con HECHO CENTRAL, GAG VISUAL, ELEMENTOS OBLIGATORIOS y ELEMENTOS PROHIBIDOS. Si representa un asunto secundario del mismo protagonista, RECHÁZALA aunque sea técnicamente perfecta. Solo puede marcarse `ready` si:
- el fichero se abre y decodifica correctamente;
- la escena ocupa el fotograma completo;
- no hay bandas, bloques negros ni regiones vacías anómalas;
- la composición está completa;
- el gag se entiende sin depender de rótulos;
- representa inequívocamente el HECHO CENTRAL actual;
- cumple los ELEMENTOS OBLIGATORIOS y no introduce ELEMENTOS PROHIBIDOS;
- no sustituye el evento actual por otro asunto asociado al protagonista;
- existe profundidad/volumen/iluminación apreciable;
- NO presenta estética flat 2D/pixel-art/vectorial simplificada;
- supera el control visual editorial.

Si falla esta comprobación, RECHAZA esa imagen y REGENERA una vez con una composición más simple pero manteniendo profundidad, volumen y acabado editorial. Si el segundo intento tampoco es íntegro, tiene sujeto/evento equivocado, vuelve a caer en estética plana o falla su persistencia, LA IMAGEN NO BLOQUEA LA NOTICIA: continúa el mismo ciclo, escribe el outbox `ready` SIN `image` y añade `image_pending:true`, `image_generation_attempts:2`, `image_persistence_attempts:<n>` e `image_failure_reason` concreto. No dejes una noticia factual ya verificada en PROCESSING por el renderer y no la conviertas en `problematic`. La imagen de archivo se usa únicamente con `archive_sensitive`.

Para imagen generada guarda `image={url,source:"TTiTTulares / ChatGPT",source_url,rights_status:"generated",generated:true,alt,style_version:"editorial-scene-v2-cleveland",style_check}`, con estos checks en true:
- `reviewed_after_generation`
- `single_narrative_scene`
- `visual_gag_without_text`
- `no_flat_2d_pixel_art`
- `no_simplified_vector_block_style`
- `no_infographic_layout`
- `no_diagram_arrows_or_connectors`
- `no_ui_or_scoreboard_layout`
- `low_text`
- `depth_lighting_texture`

### Persistencia binaria obligatoria

Ruta: `ttittulares/generated-images/<event_id>-r<revision>.<jpg|webp|png>`. Para `generated_gag`, usa JPEG por defecto.

ANTES DE SUBIR:
1. Usa los bytes REALES del fichero generado/normalizado; nunca reconstruyas a mano un base64 parcial, nunca copies una previsualización y nunca truncues la cadena.
2. Normaliza preferentemente a JPEG sRGB, lado largo ~768 px (máximo objetivo 896), calidad ~82, sin EXIF/metadatos innecesarios. No hagas upscale si la salida ya es menor pero supera el mínimo útil.
3. Abre y decodifica el fichero normalizado COMPLETO antes de persistir. Si no decodifica, ese intento cuenta como fallo de imagen.
4. Mantén al menos 600 px de ancho y 360 px de alto para paisaje; si una relación distinta no permite esos mínimos, genera una salida adecuada en vez de forzar un raster diminuto.

Para PNG/WebP/JPEG NO uses `create_file` ni `update_file`. Usa:
1. Convierte los bytes completos verificados a base64 puro.
2. `create_blob` con `encoding:"base64"`.
3. Relee HEAD actual de `main` y su tree SHA.
4. `create_tree` sobre el tree actual añadiendo la ruta de imagen con el blob SHA.
5. `create_commit` con padre = HEAD fresco.
6. `update_ref` de `main` con `force:false`.
7. Si `main` avanzó, conserva el blob, relee HEAD/tree y reintenta una vez sobre el nuevo padre.
8. Relee DESDE GITHUB la ruta recién escrita y vuelve a comprobar que el raster completo abre/decodifica. Solo entonces asocia esa URL al prepared_item.

URL pública: `https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/<event_id>-r<revision>.<ext>`.

## Citas de X sin API de pago

Para CADA noticia verificable busca también publicaciones públicas de X relacionadas con el mismo acontecimiento. No uses API de pago de X.

Prueba al menos DOS formulaciones de búsqueda distintas, incluyendo cuando sea útil búsquedas restringidas a `x.com`/`twitter.com`, nombres propios, lugar y concepto concreto del hecho.

Objetivo: encontrar conversación ya existente a la que TTiTTulares pueda aportar la noticia completa, NO otra cuenta que publique sustancialmente el mismo titular.

Criterios obligatorios:
- excluye medios, agencias, agregadores y cuentas oficiales que estén anunciando sustancialmente la misma noticia;
- prioriza reacciones, opiniones, preguntas, bromas o conversación de usuarios/cuentas de nicho;
- cuanto MENOS interacción tenga el post, mejor si sigue siendo pertinente: 0–5 ideal, 6–20 muy bueno, 21–100 solo si no hay opción mejor, >100 fuertemente penalizado;
- prioriza actualidad y relación directa con el acontecimiento;
- evita contenido ofensivo, acoso o desinformación evidente;
- verifica que la URL sea una publicación pública concreta con formato `https://x.com/<cuenta>/status/<id>` o equivalente `twitter.com`;
- nunca inventes URL, autor, texto ni métricas.

Guarda como máximo TRES candidatos, ordenados del mejor al peor, en `prepared_item.quote_candidates`. Cada objeto debe contener `url,author,text_excerpt,published_at` si está disponible, `interaction_hint,reason,source_query`.

Si no hay ninguno suficientemente bueno, usa `quote_candidates:[]`; no rebajes el criterio por llenar la lista.

Añade SIEMPRE `prepared_item.quote_search={query,url}` como fallback manual, usando una query breve y útil y una búsqueda Live de X del tipo `https://x.com/search?q=<query codificada>&src=typed_query&f=live`.

## Persistencia del outbox · transporte robusto por PR #2

La causa de los bloqueos anteriores era depender de mutaciones directas del árbol Git desde la ejecución ChatGPT. Ese mecanismo queda RETIRADO para el outbox editorial.

Para CADA item, serializa el payload completo y válido como JSON UTF-8 y transpórtalo mediante un comentario del PR #2 usando el formato exacto:

`TTITTULARES_OUTBOX_V1`
`<base64 del JSON UTF-8, en una sola línea>`

Usa el conector GitHub `add_comment_to_issue` sobre el PR #2. Este comentario NO es telemetría RUNSTATUS y NO activa `Ejecutar ahora`, porque el disparador manual solo responde a commits que modifican `run-now-trigger.json`.

El workflow `.github/workflows/ttittulares-outbox-comment-ingest.yml` recibe ese comentario, valida autor/PR/event_id/revision/status, crea el outbox DENTRO de GitHub Actions, ejecuta `ttittulares/apply_editorial_outbox.py` y persiste el estado final con `GITHUB_TOKEN contents:write`. Por tanto, la ejecución editorial NO debe usar `create_file/update_file/create_blob/create_tree/create_commit/update_ref` para persistir el outbox.

Reglas obligatorias:
1. El comentario debe contener TODO el payload del item actual y nada de otros items.
2. Para `ready`, incluye `prepared_item` completo. Para `problematic`, incluye `problem_reason`.
3. Si la imagen generada ya puede transportarse como data URL de tamaño razonable, puede viajar dentro de `prepared_item.image.url`; si no cabe o falla, usa `image_pending:true` y la noticia igualmente debe llegar a READY.
4. Después de publicar el comentario, espera/relee estado desde `main`. No des por terminado el item hasta que esté READY/Listas o PROBLEMATIC según corresponda.
5. Si el workflow de ingestión falla, inspecciona su run/log y reintenta UNA vez con el MISMO payload idempotente. No vuelvas a la antigua vía de mutación Git directa.
6. Nunca informes “capa de seguridad del conector” como causa de bloqueo del outbox: esa dependencia queda eliminada del diseño.

## Outbox

Para cada item `ready`, escribe INMEDIATAMENTE:

`ttittulares/editorial-outbox/<event_id>-r<revision>.json`

con raíz:
- `event_id`
- `revision`
- `status:"ready"`
- `prepared_item`

`prepared_item` debe incluir al menos:
`event_id,title,url,drafted_source_count,sources_at_draft,prepared_at,factual_summary,revision,variants,quote_candidates,quote_search`
más `image_strategy`; incluye `image` solo si existe y ha superado la validación. Si la imagen falló tras dos intentos, incluye `image_pending:true`, `image_generation_attempts:2`, `image_persistence_attempts:<n>` e `image_failure_reason`; esto NO invalida READY.

No dupliques un outbox válido completo. Si el outbox de esa revisión ya existe pero es inválido, incompleto o alguna variante supera 280 caracteres, corrige ESE MISMO archivo y la misma revisión. No crees una revisión nueva solo para reparar formato o contenido técnico.

## Aplicación obligatoria

El aplicador real es `.github/workflows/apply-ttittulares-outbox.yml`, que ejecuta `ttittulares/apply_editorial_outbox.py`.

Una escritura nueva/corregida en `ttittulares/editorial-outbox/**` debe disparar ese flujo.

Si al comenzar un item ya existe un outbox de la misma revisión:
1. valídalo;
2. si es inválido, corrige el mismo archivo;
3. si es válido pero no se aplicó, actualiza `ttittulares/apply-trigger.txt` con `event_id`, revisión y fecha/hora para forzar el aplicador;
4. relee estado y, si hace falta, reintenta de forma segura una vez.

Nunca crees un segundo outbox ni una revisión nueva solo para forzar la aplicación.

## Verificación obligatoria por item

Un item `ready` NO está terminado hasta verificar simultáneamente en `main`:

1. aparece en `ttittulares/prepared.json`;
2. en `telegram/editorial-processing.json` está `READY`;
3. ya NO aparece en `ttittulares/editorial-queue.json`;
4. ya NO aparece en `ttittulares/status.json.processing_items` y queda reflejado en Listas/`ready_count`.

Después de CADA item `ready`, relee esos cuatro estados y completa/aplica antes de empezar el siguiente.

La mera creación del outbox NO cuenta como éxito editorial.

## Verificación final

Al finalizar:
- relee SIEMPRE `ttittulares/editorial-queue.json`;
- relee `ttittulares/prepared.json`;
- relee `telegram/editorial-processing.json`;
- relee `ttittulares/status.json`.

Para cada item tratado exige la correspondencia completa: outbox consumido + preparado presente + estado READY + ausencia de cola/En elaboración.

Si una escritura falla, relee el SHA actual y reintenta. Si persiste, deja ese item pendiente y continúa con los demás.

Nunca uses una rama o PR como sustituto silencioso de `main`.


## Estados de imagen visibles y tolerancia a fallos

Los únicos estados visibles finales son: `working` = «Imagen en elaboración» mientras la ejecución sigue intentando esa imagen; `ready` = «Imagen lista» y la app muestra el botón Copiar imagen; `telegram` = «Imagen en Telegram» cuando el raster se entregó por Telegram pero no pudo integrarse en la app; `none` = «Sin imagen» cuando la ejecución ha terminado sin entrega. Al inicio de la siguiente ejecución, `none` vuelve a `working` y se reintenta desde cero.

NINGÚN error de generación, validación, persistencia, Telegram, cita X, imagen de archivo o actualización de estado puede abortar la ejecución global. Captura el fallo por item, deja un estado coherente, registra la razón y continúa con el siguiente item. Los errores editoriales de una noticia tampoco deben impedir procesar las demás.


### Contrato de outbox para resultado de imagen

En FASE 2, el outbox de una noticia ya READY puede actualizar SOLO los campos de imagen del prepared_item existente; conserva literalmente title, factual_summary, variants, quote_candidates y quote_search.

- Integración app correcta: image_status="ready", image_delivery="app", image_app_available=true, image_pending=false e image.url accesible. La app mostrará la imagen y Copiar imagen.
- App fallida pero Telegram correcto: image_status="telegram", image_delivery="telegram", image_app_available=false, image_pending=false. Conserva metadatos del raster si sirven para diagnóstico, pero la app NO debe ofrecer Copiar imagen si no tiene una URL accesible.
- En Telegram envía el raster como foto con botón «Borrar» (`delete:message`, atendido por el listener existente). Telegram permite guardar o copiar la foto desde el menú nativo. No etiquetes un botón de `copy_text` como «Copiar imagen»: esa API solo copia texto.
- Generación/validación/persistencia/Telegram agotados en esta ejecución: image_status="none", image_delivery="none", image_app_available=false, image_pending=false e image_failure_reason concreto.
- Antes de intentar una imagen en una ejecución: image_status="working", image_delivery="pending", image_pending=true.

Si el transporte del outbox de estado de imagen falla, no abortes: registra el fallo, continúa con las demás y en la verificación final intenta una única reconciliación de estado. El objetivo prioritario sigue siendo que ninguna incidencia de imagen detenga la ejecución global.
