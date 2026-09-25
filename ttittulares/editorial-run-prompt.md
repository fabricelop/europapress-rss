# TTiTTulares · flujo editorial común

Este archivo es la ÚNICA fuente de verdad para la ejecución editorial de TTiTTulares. Debe ser usado tanto por el botón `Ejecutar ahora` como por las programaciones automáticas. La lógica de activación, horario, anti-solape y telemetría pertenece al envoltorio que invoque este archivo y NO se redefine aquí.

## Ámbito y estado

Usa el conector GitHub disponible para `fabricelop/europapress-rss`. Trabaja EXCLUSIVAMENTE con TTiTTulares y con estado fresco de la rama `main`.

GitHub es la única persistencia/estado del flujo. Web se usa solo para investigación y verificación actual, búsqueda de imágenes existentes y búsqueda de publicaciones públicas de X.

No uses Telegram. No proceses TTendencias ni SeLoRecordamos. No despliegues Vercel. No cambies radar, fuentes, umbrales ni ninguna programación/automatización.

## Cola y orden de trabajo

1. Lee SIEMPRE `ttittulares/editorial-queue.json` desde `main`.
2. Si `count=0`, termina el flujo editorial sin búsquedas web ni escrituras.
3. Si hay pendientes, procesa TODOS los items, del más antiguo al más reciente.
4. Procesa cada item de forma independiente y completa el ciclo de ese item antes de empezar el siguiente: investigar → redactar → imagen → citas X → outbox → aplicación → verificación.
5. Relee estado fresco antes de cada escritura. Ante conflicto, relee el SHA actual y reintenta de forma segura.
6. Un item difícil o fallido no debe bloquear los demás.

Usa todos los campos disponibles del item, incluidos `event_id,title,url,sources,source_count,selected_at,selection_mode,revision,rewrite_request,parent_event_id,update_context,with_image,image_mode,image_instruction`.

## Verificación factual

Verifica los hechos esenciales con las fuentes suministradas y búsquedas actuales fiables cuando haga falta.

- Política/controversia: redacción factual y neutral.
- Deportes: confirma expresamente el estado/resultado justo antes de redactar. Nunca presentes como final un evento que siga en curso o cuyo resultado no hayas confirmado.
- Si tras DOS búsquedas distintas no puedes verificar suficientemente el asunto, escribe inmediatamente `ttittulares/editorial-outbox/<event_id>-r<revision>.json` con `event_id`, `revision`, `status:"problematic"` y un `problem_reason` concreto. Continúa con los demás items.

## Redacción

Para cada item verificable genera exactamente cuatro variantes: `Principal`, `A`, `B`, `C`.

- `Principal`: noticia factual; `remate:""`.
- `A/B/C`: el campo `remate` empieza exactamente por `🌶️ `.
- `text` de A/B/C = texto Principal + DOS saltos de línea reales + remate.
- No uses secuencias `\\n` visibles.
- Comprueba expresamente que CADA `text` completo, Principal y A/B/C, mide como máximo 280 caracteres.
- Genera para cada variante una URL `https://twitter.com/intent/tweet?text=` con el texto exacto correctamente codificado.
- Los remates deben ser específicos del hecho, diferenciados entre sí y evitar plantillas genéricas.
- Nunca hagas humor a costa de víctimas, abusos, tragedias o sufrimiento. Si hay sátira en asuntos sensibles, dirígela solo a responsables, gestión, instituciones o contradicciones públicas verificadas.

## Imagen existente

Si `with_image=true`, intenta encontrar una imagen EXISTENTE, real y pertinente. Nunca generes una imagen para TTiTTulares.

1. Haz una búsqueda específica del acontecimiento.
2. Si falla, prueba una segunda vía, incluida la página original o su `og:image`.
3. Prioriza fuente oficial/primaria y después medios fiables.
4. Verifica que la imagen Y la página de origen correspondan realmente al MISMO acontecimiento, persona o lugar del item. No uses una imagen de otro tema por coincidencia de palabras, nombres o etiquetas.
5. Si no puedes verificar derechos, usa `rights_status:"unverified"`.
6. Si existe una imagen adecuada, guarda `prepared_item.image={url,source,source_url,rights_status,alt}`.
7. La ausencia de una imagen adecuada NO bloquea el tuit. No inventes una URL ni uses una imagen dudosa para rellenar el campo.

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
