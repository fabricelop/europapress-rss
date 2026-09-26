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
5. Si hay pendientes, usa DOS fases de prioridad: primero TODOS los `preparing`/`update` del más antiguo al más reciente; solo después reintenta los `problematic` que sigan en Top 10. Un problematic antiguo NUNCA puede hacer starvation de tendencias nuevas.
6. PROCESAMIENTO ESTRICTAMENTE SECUENCIAL END-TO-END: para cada tendencia/grupo completa TODO su ciclo antes de empezar la siguiente: investigar → redactar Principal/A/B/C → generar y revisar imagen → guardar checkpoint de imagen → persistir outbox ready → esperar/verificar aplicación → confirmar que está en `prepared.json` y fuera de cola. Solo entonces pasa al siguiente item. NO investigues todas primero ni generes todas las imágenes al final.
7. Una tendencia `problematic` se reintenta automáticamente mientras siga en el Top 10, pero siempre al final de la pasada. Si ya salió del Top 10, no se fuerza otro intento.
8. Un fallo de un item no debe bloquear los siguientes: registra ese item pendiente/problematic según corresponda y continúa con el siguiente.
9. Relee estado fresco antes de cada escritura. Ante conflicto, relee SHA y reintenta de forma segura.

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

## Persistencia de imagen — hand-off seguro por outbox

La automatización programada NO debe intentar escribir binarios directamente en GitHub con `create_blob/create_tree/create_commit/update_ref`. Esa vía puede quedar bloqueada por controles del conector y era la causa de que el trabajo editorial se quedara en `preparing`.

La vía oficial es ahora:

1. Genera el raster real.
2. Si sale a más resolución, puedes reducirlo localmente si las herramientas lo permiten; de lo contrario entrega el original a Actions: objetivo aproximado **512 px de lado largo** (mínimo 480 px), preferentemente JPEG/WebP eficiente. No necesitamos calidad premium: es una imagen para X.
3. Inspecciona el raster REAL.
4. Conserva la data URL real devuelta por el generador o convierte programáticamente sus bytes a base64 y usa en `prepared_item.image.url` una data URL válida `data:image/jpeg;base64,...` / WebP / PNG.
5. Mantén `generated:true`, `rights_status:"generated"`, `source:"TTendencias / ChatGPT"`, `style_version:"editorial-scene-v2-cleveland"` y todos los `style_check` requeridos.
6. Persiste **solo el JSON UTF-8 del outbox** con la operación de texto normal de GitHub (`create_file` o `update_file` según corresponda). No uses operaciones Git de bajo nivel para la imagen.
7. El workflow `.github/workflows/ttendencias-editorial-apply.yml` ejecuta `apply_editorial_outbox.py`: valida la data URL, crea el fichero binario real en `trends/generated-images/<id>-r<revision>.<ext>`, sustituye la data URL por la URL raw de GitHub y guarda `prepared.json`.
8. Tras la aplicación, verifica que `prepared_item.image.url` YA NO es data URL, sino la URL raw del raster persistido, y que el fichero existe.

El binario inline original puede alcanzar 12 MB. Actions valida y normaliza a JPEG <=350 KB; la compresión local es opcional. Esta arquitectura delega la escritura binaria en Actions. Confirma siempre que el transporte textual y la aplicación han terminado.

RECUPERACIÓN DE IMAGEN Y TRANSPORTE — CONTRATO v3:
Antes de generar, lee desde main `trends/image-cache/<id>-r<revision>.json` y el outbox de ese id/revision si existen. Si hay imagen válida del MISMO id/revision y corresponde al brief actual, reutilízala; no la generes de nuevo por un fallo de texto, escritura o aplicación. Un 404 solo significa que aún no existe checkpoint.

Conserva programáticamente el resultado COMPLETO de imagegen al recibirlo; no pierdas sus bytes entre herramientas. Si el generador se invoca en functions.exec, guarda su resultado con store("ttendencias-image-"+id+"-r"+revision, result) ANTES de mostrarlo con generatedImage(result). Si devuelve image_url de tipo data:image/...;base64, úsala directamente desde el objeto guardado: NO la transcribas, no la resumas, no la imprimas ni reconstruyas base64 a mano. Si devuelve una ruta, usa únicamente el archivo real devuelto y conserva sus bytes en el entorno que pueda leerlo. No inventes rutas ni URLs. Una ruta local no es una URL de imagen utilizable por GitHub Actions.

La compresión LOCAL es opcional, nunca una condición para persistir. Si los bytes originales son accesibles pero no puedes comprimirlos, entrega la data URL original (máximo 12 MB decodificados); Actions valida y normaliza a JPEG ligero <=350 KB. Objetivo de salida ~512 px, manteniendo ancho >=480 y alto >=270 sin ampliar. No repitas imagegen por falta de compresión local.

Tras revisar y aceptar visualmente la imagen, escribe inmediatamente el MISMO outbox `trends/editorial-outbox/<id>-r<revision>.json` con {id,name,revision,status:"image_checkpoint",image:<metadatos completos y data URL real>}. Usa create_file/update_file UTF-8 normales. El aplicador guarda el raster y `trends/image-cache/<id>-r<revision>.json`, mantiene la solicitud pendiente y consume el checkpoint. Relee el cache: solo entonces considera la imagen recuperable en otra ejecución. Este checkpoint no es READY ni crea otro item/revisión.
A continuación, completa el texto y escribe el outbox ready de la misma revisión usando image del cache (URL raw real). Si algo falla después, la siguiente ejecución parte del cache. Si ya había un outbox READY sin aplicar, reanúdalo sin reemplazarlo por un checkpoint. Si una escritura devuelve error, relee primero: puede haberse confirmado. Nunca sobrescribas trabajo más reciente.

Construye el objeto JSON y JSON.stringify en el mismo entorno que posee la data URL; pasa esa cadena directamente a create_file/update_file. No hace falta escribir Git blobs binarios. Si la herramienta rechaza una operación por autorización, registra el rechazo exacto y conserva lo recuperable; no intentes eludirlo por otro canal ni afirmes que has eliminado controles externos. Distingue falta de bytes, compresión, rechazo de escritura y error de aplicación.

Un error técnico de imagen NO convierte una tendencia verificada en problematic: conserva su estado pendiente y continúa con las demás. Espera/verifica como máximo tres lecturas por item; si sigue pendiente, informa con precisión y continúa sin regenerar. La ejecución solo informa éxito para items realmente aplicados.

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
