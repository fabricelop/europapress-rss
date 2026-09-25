# TTendencias · flujo editorial común

Este archivo es la ÚNICA fuente de verdad para la elaboración editorial de TTendencias. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La activación, horarios, anti-solape y telemetría pertenecen al envoltorio que invoque este archivo y no se redefinen aquí.

## Ámbito y estado

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTendencias y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa para investigar por qué una tendencia es tendencia AHORA y verificar hechos actuales. La imagen final de TTendencias debe ser original generada; no uses imágenes encontradas en Internet como imagen final.

No uses Telegram. No proceses TTiTTulares ni SeLoRecordamos. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Estado inicial y watchdog

1. Lee SIEMPRE `trends/editorial-queue.json` desde `main`.
2. Lee `trends/recent.json` y `trends/editorial-config.json`.
3. Si `trends/recent.json.captured_at` supera 20 minutos, actualiza `trends/refresh-trigger.txt` en `main` para pedir una captura fresca y después relee `trends/editorial-queue.json`, `trends/recent.json` y `trends/editorial-config.json`.
4. Si la cola queda vacía, termina el flujo editorial sin investigación web ni escrituras adicionales.
5. Si hay pendientes, procesa TODOS los grupos/items del más antiguo al más reciente. La cola puede contener `preparing`, `update` y también `problematic`.
6. Una tendencia `problematic` se reintenta automáticamente mientras siga en el Top 10. Si ya salió del Top 10, no debe aparecer en la cola editorial y no se fuerza ningún nuevo intento.
7. Un fallo no debe bloquear los demás.
8. Relee estado fresco antes de cada escritura. Ante conflicto, relee SHA y reintenta de forma segura.

## Agrupación

Agrupa únicamente cuando sea inequívoco que varios términos describen el MISMO acontecimiento real y tienen la misma `revision`.

Usa como pistas `batch_id`, `requested_together`, `captured_with`, nombres, contexto y web. El líder es el más antiguo por `requested_at`. Genera UN SOLO outbox del líder y guarda todos los términos cubiertos en `prepared_item.related_trends`.

Si las revisiones difieren o la relación no es inequívoca, no agrupes.

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

Usa el rank ACTUAL de `trends/recent.json` al redactar: Top10 = `Tn`; fuera del Top10, cuando proceda según el estado actual, usa `R<mejor_puesto>`.

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

## Imagen — obligatoria y generada

Sigue SIEMPRE `trends/editorial-config.json.editorial.image_policy`. La imagen es obligatoria para cualquier item `ready`.

Genera una imagen editorial ORIGINAL en PNG, WebP o JPEG. No sustituyas esta generación por una búsqueda web y no uses SVG.

Línea visual aprobada: `editorial-scene-v2-cleveland`.

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

En temas sensibles, nunca conviertas víctimas o sufrimiento en objeto humorístico. Si no hay vía humorística segura, usa una ilustración editorial seria y respetuosa.

## Persistencia de imagen

Persistir el raster generado REAL es obligatorio antes de marcar `ready`.

### Vía binaria GitHub obligatoria

Para PNG/WebP/JPEG NO uses `create_file` ni `update_file`: esas acciones son para texto UTF-8 y no son la vía de persistencia binaria.

Usa SIEMPRE este procedimiento con el conector GitHub:

1. Obtén los bytes REALES de la imagen generada y conviértelos a base64 puro, sin prefijo `data:image/...;base64,`.
2. Llama a la acción GitHub `create_blob` con:
   - `repository_full_name:"fabricelop/europapress-rss"`
   - `encoding:"base64"`
   - `content:<base64 real del raster>`
   Guarda el SHA devuelto.
3. Lee de nuevo el HEAD actual de `main` y su commit/tree actuales.
4. Crea un árbol con `create_tree`, usando como `base_tree_sha` el árbol actual de `main`, y añade exactamente:
   - `path:"trends/generated-images/<id>-r<revision>.<webp|png|jpg>"`
   - `mode:"100644"`
   - `type:"blob"`
   - `sha:<SHA devuelto por create_blob>`.
5. Crea un commit con `create_commit`, padre = HEAD fresco de `main`, mensaje breve `TTendencias: imagen <name> r<revision>`.
6. Avanza `main` con `update_ref`, `branch_name:"main"`, `sha:<nuevo commit>`, `force:false`.
7. Si `update_ref` falla por carrera porque `main` cambió, NO regeneres la imagen: conserva el mismo blob SHA, relee HEAD/tree frescos, recrea árbol+commit sobre el nuevo padre y reintenta UNA vez.
8. Verifica por GitHub que la ruta existe en `main` y que apunta al blob esperado. Después verifica que la URL raw corresponde a la imagen generada y que el raster abre completo.

Esta vía está explícitamente autorizada para los raster generados de TTendencias. No concluyas “no puedo persistir bytes” sin haber descubierto e intentado `create_blob` con `encoding:"base64"` y el flujo Git tree/commit/ref anterior.

Después guarda:
`prepared_item.image={url,source:"TTendencias / ChatGPT",source_url,rights_status:"generated",generated:true,alt,style_version,style_check}`.

Si realmente no puedes obtener los bytes del raster generado, o el raster no supera el control visual, no marques `ready`: deja `image_generation_status:"pending_renderer"` y una nota técnica concreta y continúa con los demás. Pero una imposibilidad de usar `create_file/update_file` NO cuenta como fallo binario porque la vía correcta es `create_blob(base64)`.

Si `editorial-config.json` permite explícitamente fallback raster inline y dispones de bytes reales, una data URL base64 válida puede usarse solo como fallback técnico; no sustituye la persistencia Git normal cuando `create_blob` funciona.

## Outbox

### Persistencia textual obligatoria

El outbox JSON es parte crítica del hand-off y NO puede quedar solo en memoria de la ejecución.

Para escribir `trends/editorial-outbox/<id>-r<revision>.json`, usa preferentemente la misma vía Git de bajo nivel que para los binarios, pero con contenido UTF-8:

1. Serializa el JSON completo y válido.
2. `create_blob` con `encoding:"utf-8"` y el contenido exacto.
3. Relee HEAD y tree actuales de `main`.
4. `create_tree` sobre el tree fresco con una entrada `100644/blob` para la ruta exacta del outbox.
5. `create_commit` con padre = HEAD fresco.
6. `update_ref` de `main` con `force:false`.
7. Si `main` avanzó, conserva el blob SHA, relee HEAD/tree y reintenta UNA vez sobre el nuevo padre.
8. Verifica con una lectura fresca que el outbox existe en `main` y que `id/revision/status` coinciden.

`create_file/update_file` pueden usarse para texto si funcionan, pero un rechazo de esas acciones NO autoriza a abandonar: debes intentar explícitamente la vía `create_blob(utf-8) → create_tree → create_commit → update_ref`. No informes “fallo de escritura” hasta haber probado ambas vías disponibles.

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
