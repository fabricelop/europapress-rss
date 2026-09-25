# TTiTTulares · flujo editorial común

Este archivo es la ÚNICA fuente de verdad para la ejecución editorial de TTiTTulares. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La lógica de activación, horario, anti-solape y telemetría pertenece al envoltorio que invoque este archivo y NO se redefine aquí.

## Ámbito y estado

**ACCESO GITHUB OBLIGATORIO.** Usa el conector GitHub conectado para `fabricelop/europapress-rss`. En ejecuciones programadas el conector puede estar expuesto mediante Code Mode/`functions.exec`; DEBES descubrirlo y usar el mecanismo disponible antes de concluir que GitHub no está accesible. No prohíbas ni evites `functions.exec` si es la vía que expone el conector. No sustituyas una operación GitHub por web pública.

Tu primera operación editorial real debe ser leer desde `main` `ttittulares/editorial-queue.json`. Si hay pendientes, durante ESA MISMA ejecución debes intentar escrituras reales en GitHub conforme al flujo (outbox/aplicación/verificación). No termines con un plan, diagnóstico o resumen sin haber intentado procesar la cola. Si una llamada al conector falla de forma transitoria, redescubre/reintenta con estado fresco antes de abandonar.

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTiTTulares y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa para investigación/verificación actual, para el fallback de imagen de archivo cuando corresponda y para búsqueda de publicaciones públicas de X. La imagen editorial original se genera con el generador de imágenes disponible y se persiste en GitHub.

No uses Telegram. No proceses TTendencias ni SeLoRecordamos. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Cola y orden de trabajo

1. Lee SIEMPRE `ttittulares/editorial-queue.json`, `ttittulares/status.json`, `telegram/editorial-processing.json` y `telegram/events.json` desde `main`.
2. Al inicio guarda una FOTO de las filas `status:"PROBLEMATIC"` de `telegram/editorial-processing.json`. Esa es la fuente de verdad para los reintentos; los nuevos `PROBLEMATIC` creados durante esta misma pasada se dejan para la SIGUIENTE ejecución.
3. Construye un mapa de `telegram/events.json.events` por `id/event_id`. Para cada noticia usa sus `appearances` como EVIDENCIA MULTIFUENTE estructurada: `source,title,url,first_seen`.
4. Procesa primero TODOS los items de `editorial-queue.json`, del más antiguo al más reciente.
5. Después de terminar la cola activa, procesa las problemáticas que estaban en la foto inicial.
6. Si no había ni cola activa ni problemáticas iniciales, termina sin búsquedas web ni escrituras.
7. Procesa cada item de forma independiente y completa su ciclo antes de seguir. Un item difícil o fallido NUNCA bloquea los demás.
8. Relee estado fresco antes de cada escritura. Ante conflicto, relee el SHA actual y reintenta de forma segura.

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

Si `with_image=true`, aplica exactamente la misma línea visual y el mismo control de calidad de TTendencias, con la única excepción editorial de `archive_sensitive` para noticias en las que el humor visual no proceda.

### Decisión editorial

- Por defecto genera una imagen editorial ORIGINAL raster PNG/WebP/JPEG con un gag visual específico de ESTA noticia y guarda `prepared_item.image_strategy="generated_gag"`.
- Línea visual aprobada: `editorial-scene-v2-cleveland`.
- La referencia de estilo NO significa flat 2D, pixel-art, vectorial simplificado ni formas geométricas planas. Esas estéticas están expresamente rechazadas para TTiTTulares.
- La prioridad es, en este orden: 1) gag/escena entendible de inmediato; 2) calidad de ilustración editorial; 3) composición con profundidad, iluminación y volumen suficientes; 4) robustez del raster; 5) detalle fino.
- Usa detalle medio/alto cuando sea viable, composición limpia, pocos elementos importantes y alrededor de 1024 px en el lado largo cuando la herramienta lo permita. La imagen debe verse cuidada y de calidad en móvil/X, no como boceto, iconografía plana ni clip-art.

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

Si hay víctimas, abusos, tragedia, sufrimiento, catástrofe o cualquier noticia en la que un gag cómico resulte editorialmente inapropiado, NO generes humor. Guarda `prepared_item.image_strategy="archive_sensitive"` y conserva el mecanismo anterior: imagen EXISTENTE del mismo acontecimiento, priorizando fuente oficial/primaria y después medios fiables. Segunda vía: página original/og:image. Derechos no verificados => `rights_status:"unverified"`.

Un fallo técnico o DE ESTILO del generador NO convierte una noticia apta para gag en `archive_sensitive`. No uses foto de archivo como sustituto técnico del renderer.

### Control del raster generado

DESPUÉS DE GENERAR, inspecciona la imagen REAL, no solo el prompt. Solo puede marcarse `ready` si:
- el fichero se abre y decodifica correctamente;
- la escena ocupa el fotograma completo;
- no hay bandas, bloques negros ni regiones vacías anómalas;
- la composición está completa;
- el gag se entiende sin depender de rótulos;
- existe profundidad/volumen/iluminación apreciable;
- NO presenta estética flat 2D/pixel-art/vectorial simplificada;
- supera el control visual editorial.

Si falla esta comprobación, RECHAZA esa imagen y REGENERA una vez con una composición más simple pero manteniendo profundidad, volumen y acabado editorial. Si el segundo intento tampoco es íntegro o vuelve a caer en estética plana, no marques `ready`: deja el item en elaboración para un intento posterior de renderer y continúa con los demás. No lo conviertas en `problematic`. La imagen de archivo se usa únicamente con `archive_sensitive`.

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

Ruta: `ttittulares/generated-images/<event_id>-r<revision>.<webp|png|jpg>`.

Para PNG/WebP/JPEG NO uses `create_file` ni `update_file`. Usa exactamente el mecanismo de TTendencias:
1. Obtén los bytes reales del raster y conviértelos a base64 puro.
2. `create_blob` con `encoding:"base64"`.
3. Relee HEAD actual de `main` y su tree SHA.
4. `create_tree` sobre el tree actual añadiendo la ruta de imagen con el blob SHA.
5. `create_commit` con padre = HEAD fresco.
6. `update_ref` de `main` con `force:false`.
7. Si `main` avanzó, conserva el blob, relee HEAD/tree y reintenta una vez sobre el nuevo padre.
8. Verifica que la ruta existe en `main` y que la URL raw abre el raster íntegro.

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
y `image` si existe.

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
