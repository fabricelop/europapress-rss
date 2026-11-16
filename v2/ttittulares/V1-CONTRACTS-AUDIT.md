# TTiTTulares V2 — auditoría de contratos de V1

**Paso 1 del roadmap: completado como auditoría documental de solo lectura.**  
**Estado:** inventario y decisiones de reutilización preparados; no se ha empezado todavía a implementar el motor de noticias V2.

## 1. Alcance, fuentes y corte

Esta auditoría identifica los contratos funcionales que TTiTTulares V1 utiliza actualmente y separa lo que conviene reutilizar de lo que debe reconstruirse en limpio.

- Repositorio: `fabricelop/europapress-rss`.
- Rama de referencia V1: `main`, fijada en el commit [`108ca043d5a288b72dfa654745199cae49b64696`](https://github.com/fabricelop/europapress-rss/commit/108ca043d5a288b72dfa654745199cae49b64696), del **16/11/2026 15:40:50 UTC**.
- Rama de trabajo V2: `feature/ttactualidad-v2-clean`, separada de V1. En el momento de esta auditoría contenía 318 archivos bajo `v2/ttendencias/` y **ningún archivo bajo `v2/ttittulares/`**.
- Snapshot de estado de V1: `status.json` actualizado a las 15:33:58 UTC; radar a las 15:31:41 UTC.

La revisión cubrió radar y fuentes, elegibilidad, identidad y deduplicación, contratos editoriales, ejecución Windows, transporte/outbox, aplicación a READY/Listas, decisiones manuales, imágenes de archivo, ImageGen y asociación de originales.

**Límites de la auditoría:** se han leído los archivos versionados y workflows de GitHub. No se ha accedido al PC Windows ni a sus archivos locales, no se ha inspeccionado la conversación viva de Chrome y no se ha ejecutado ningún trabajo editorial o de imagen. Por tanto, no se certifican procesos locales, banderas locales ni ejecución real de los cron solo por estar definidos en código.

## 2. Flujo funcional V1 observado

V1 no es un único ejecutor. Se compone de varios servicios y estados coordinados:

```text
Fuentes / radar
    ↓
Agrupación de apariciones y validación de evidencia
    ↓
Elegibilidad (4 familias de fuentes, frescura, filtros, identidad)
    ↓
PROCESSING + event_id/revisión
    ↓
Solicitud / trigger en rama de control
    ↓
Listener dedicado de Windows
    ↓
Ejecutar.js local + sesión ChatGPT persistente
    ↓
Investigación, redacción y resultado editorial
    ↓
Outbox TTITTULARES_OUTBOX_V1
    ↓
Ingesta y validación del outbox
    ↓
prepared.json + READY/Listas + status/decisiones
    ↓
UI editorial / decisión humana / publicación autorizada

En paralelo, después de READY:
prepared.json
    ↓
Reparador y política de trabajos de imagen
    ↓
control/ttittulares-run-trigger-v2/image-runs
    ↓
Listener Windows + ImageBridge + ChatGPT Images
    ↓
Original raster identificado por comando, noticia y revisión
    ↓
Captura / caché local / image-outbox
    ↓
Validación y asociación por event_id + revisión + SHA
    ↓
generated-images/ + site-ai-images.json + prepared.json
    ↓
Web / APP
```

La búsqueda de fotografía real de archivo es otra función: puede recuperar una imagen HTTPS desde páginas de fuentes. **No es ImageGen** y no debe confundirse con la ilustración IA.

## 3. Contratos V1 que conviene conservar

### 3.1 Radar, fuentes y umbral

Configuración y código relevantes:

- `telegram/radar_no_d1.py`: captura las fuentes generales, deportivas y suplementarias; realiza extracción, fallbacks, agrupación, validación de consenso y persistencia.
- `ttittulares/config.json`: `minimum_sources = 4`, ventana de espera de 24 horas, zona horaria `Europe/Madrid`.
- `ttittulares/auto_queue.py`: transforma acontecimientos elegibles en trabajo editorial `PROCESSING`.
- `ttittulares/treated_news.py`: identidad histórica, detección de mismo hecho y protección contra recrear una noticia ya tratada.

Reglas funcionales que se deben conservar:

1. El umbral automático es **cuatro fuentes generales independientes**, no cuatro URLs ni cuatro medios de una misma familia.
2. Las fuentes suplementarias de descubrimiento ayudan a detectar y agrupar, pero no cuentan para el umbral editorial ni para la salud de fuentes generales.
3. Las noticias que no alcancen el umbral dentro de 24 horas caducan del radar automático.
4. Una actualización del mismo acontecimiento solo abre una revisión nueva cuando hay cambio material verificable; una nueva URL o una paráfrasis no bastan.
5. Se filtran noticias rutinarias/no pertinentes y se deduplican por URL, título y memoria de hechos tratados.
6. Las decisiones terminales del editor se respetan: publicada, desestimada o borrada no se reabren automáticamente.
7. Se mantienen las excepciones explícitas de intervención del usuario: una selección manual puede pedir investigación con menos fuentes; una propuesta manual puede empezar sin fuentes, pero no permite inventar evidencias ni darla por READY sin verificar el hecho.

**Identidad:** cada noticia se conserva mediante `event_id`; cada reelaboración material usa `revision` y, cuando corresponda, `parent_event_id`. La identidad no debe depender del título visible, del orden de la cola ni de la posición en Listas.

### 3.2 Contrato editorial

La fuente normativa principal es `ttittulares/editorial-run-prompt.md`. Hay que trasladar su contenido editorial vigente, no copiar literalmente secciones heredadas que el propio documento marca como retiradas u obsoletas.

Reglas que se deben mantener:

- Investigar el acontecimiento concreto y actual; contrastar el hecho esencial con fuentes fiables antes de redactar.
- Conservar fuentes, enlaces y qué hecho sostiene cada fuente.
- Un tuit por noticia, con texto factual conciso y **máximo 256 caracteres en el conjunto completo**.
- Dos hashtags específicos y verificables; tres solo si son concretos y caben.
- Un único remate `🌶️` solo si existe uno ingenioso, específico, original y respetuoso. Si no procede, el texto factual con hashtags es válido y `tweet.remate` queda vacío.
- Prohibidos los antirremates autorreferenciales como «no hay chiste» o «aquí no hay chiste». Si no hay remate, se cierra sobriamente con los hechos.
- No inventar cifras, causas, responsables, declaraciones ni contexto.
- Las noticias sensibles requieren tono y tratamiento visual apropiados; la sensibilidad no permite trivializar víctimas ni daños.
- Las reelaboraciones parciales respetan su alcance. Un cambio solo de remate no puede alterar hechos, titular o fuentes; una reinvestigación sí vuelve a contrastar.
- Las valoraciones de remates sirven para aprender el estilo, no para repetir fórmulas ni copiar los ejemplos.

La pasada editorial no debe llamar a ImageGen ni esperar a que haya imagen. **La imagen nunca es requisito para cerrar el texto como READY.**

### 3.3 Estados y persistencia

| V1 | Función observada | Contrato V2 recomendado |
|---|---|---|
| Radar / acontecimiento elegible | Evidencia reunida y validación de umbral | Estado de detección separado del estado editorial |
| `PROCESSING` | Trabajo editorial pendiente o en curso | Trabajo persistente con ID/revisión y lease/heartbeat |
| `PROBLEMATIC` | Incidencia que requiere validación explícita | Incidencia aislada por trabajo; no frenar el resto de la cola |
| `prepared.json` / READY | Resultado editorial utilizable en Listas | Registro READY inmutable por revisión |
| `decisions.json` | Decisión del editor: publicada, desestimada o borrada | Ledger append-only de decisiones humanas |
| `treated-stories.json` | Memoria compacta de identidad y hechos tratados | Índice deduplicador, no sustituto de la hemeroteca |
| `status.json` | Proyección operativa de colas, fuentes y contadores | Estado derivado; no fuente única de verdad |

La cola compacta `ttittulares/editorial-queue.json` es una proyección. La lógica V1 también usa `telegram/editorial-processing.json`, a pesar de que el canal de entrega Telegram fue retirado. Ese nombre es una dependencia histórica de almacenamiento, **no** una razón para incorporar Telegram al diseño V2.

`prepared.json` es una lista mutable de elementos preparados/READY; por sí sola no garantiza una hemeroteca permanente. V2 debe separar explícitamente:
- cola y trabajos activos;
- registro editorial inmutable por ID/revisión;
- estado READY para la interfaz;
- decisiones y recibos;
- archivo histórico de noticias que sobreviva a la salida de Listas.

### 3.4 Outbox y confirmación de escritura

En V1, el resultado de ChatGPT no se considera terminado por existir en una conversación o por haber recibido un ACK de lanzamiento.

Cadena observada:
1. El resultado se prepara como `TTITTULARES_OUTBOX_V1`.
2. El transporte lo ingesta y valida identidad, revisión y forma del payload.
3. `apply_editorial_outbox.py` vuelve a leer el estado, rechaza revisiones obsoletas y decisiones terminales, valida el tuit y aplica el resultado.
4. El item entra en `prepared.json`, se marca READY y se actualiza el estado/cola compacta.
5. Se relee la fuente autoritativa para comprobar que el resultado quedó persistido.

V1 utiliza el issue #164 como transporte vigente de nuevos outboxes; PR #2 se conserva para control/telemetría y no es el destino preferido de nuevas escrituras. Los comentarios se retiran solo después de aplicar con éxito.

**Para V2 se conserva la semántica transaccional, no el mecanismo concreto:** outbox propio de V2, ID/revisión, escritura atómica, validación, idempotencia, readback de GitHub y recibo inequívoco. No se deben heredar el issue #164, PR #2 ni las colas `telegram/*` como backend V2.

### 3.5 Acciones y publicación

V1 tiene acciones web para reelaborar, desestimar y marcar como publicada, además de decisiones persistentes e indicadores de remates/imágenes. Las decisiones humanas deben sobrevivir a recargas y a cambios de versión.

No se debe inferir que una noticia está publicada únicamente porque aparezca como READY ni porque se haya construido un enlace de X. La publicación exterior requiere su propio consentimiento y recibo verificable. La reconstrucción V2 no debe activar publicación automática como efecto lateral del trabajo editorial.

## 4. Imágenes V1: dos canales distintos

### 4.1 Fotografía de archivo

El aplicador editorial puede buscar metadatos de imagen en las páginas de fuentes. Valida HTTPS, tipo raster y dimensiones; conserva URL, fuente, página de origen, texto alternativo y estado de derechos. Si no encuentra una imagen verificable, registra que no hay fallback. Esta fase no usa ChatGPT Images y no bloquea READY.

### 4.2 Imagen IA / Gag editorial

La arquitectura versionada consta de:

1. Elegibilidad posterior a READY.
2. Job de imagen separado con `event_id`, revisión y `command_id`.
3. Prompt de imagen basado en el texto editorial ya persistido.
4. Bridge Windows que envía el prompt a ChatGPT Images.
5. Recuperación del raster exacto del turno del comando, nunca una imagen aproximada por título.
6. Caché local del original, validación de MIME, tamaño y dimensiones, y SHA-256.
7. Outbox y asociación con el ID/revisión exactos.
8. Sincronización de `prepared.json`, `generated-images/` y `site-ai-images.json`.

La asociación no vuelve a generar la imagen. El consumidor `TTiTTularesWebImages.cjs` **no genera ni envía prompts**: consume un resultado existente, inspecciona únicamente el navegador generador 9223 y valida el comando y el raster. El receptor/consumidor no debe confundir un prompt enviado, un job LAUNCHED o una vista previa con un original guardado y asociado.

Reglas visuales que conviene mantener:
- Un gag visual central, comprensible de un vistazo, basado en el hecho/remate exacto.
- No ilustrar la guindilla: `🌶️` es solo marcador tipográfico del remate.
- Estilo variable dentro de una dirección editorial común; evitar que todas las imágenes parezcan la misma plantilla.
- En asuntos sensibles, imagen sobria y respetuosa; nunca inventar una escena, víctima o hecho visual.
- El original debe conservar buena resolución y tener identidad comprobable.

### 4.3 Contradicción operativa que V2 debe resolver

V1 contiene varias señales que no son equivalentes:

- `ttittulares/config.json` declara `images.generate=false`, `generation_mode=manual_selected_jobs` y que la pasada editorial no solicita IA.
- `ttittulares/auto_listas_images_policy.json` declara `enabled=true`, permite un job automático post-READY por pasada, un solo job activo y separación mínima de 15 minutos.
- `repair-ttittulares-listas.yml` tiene cron cada cinco minutos y contiene una fase que puede encolar trabajos IA automáticos después de READY.
- `ttittulares-auto-listas-images.yml` y `ttittulares-ai-image-apply.yml` están convertidos en no-op/retirados; **eso no equivale a desactivar el workflow `repair-ttittulares-listas.yml`**.
- El listener Windows comprueba una bandera local `C:\TTiTTulares\V1-ImageGen-Paused.flag`. Su existencia/estado actual no se pudo verificar en esta auditoría.
- El índice leído en `control/ttittulares-run-trigger-v2` estaba vacío en la instantánea de las 11:01:19 UTC; no acredita que la política esté permanentemente parada.

Por tanto, no copiar literalmente los flags de V1. En V2 debe existir **una única política autoritativa** que decida cuándo crear job IA (por ejemplo, al entrar en READY, con elegibilidad explícita), cómo pausar, cuántos jobs pueden estar activos y cómo reintentar. La elección no debe estar repartida entre config, workflow, listener y bandera local sin una lectura común y observable.

## 5. Infraestructura V1 que conviene sustituir

| Componente actual | Límite observado | Sustitución prevista en V2 |
|---|---|---|
| `TTiTTularesDedicatedListener.ps1` | Listener Windows dedicado y de larga duración; atiende triggers y trabajos de imagen | Consumidores V2 independientes, supervisor liviano y trabajos persistentes |
| `C:\TTiTTulares\Ejecutar.js` | Ejecutor local que no está versionado en `main`; su implementación interna no se pudo auditar aquí | Runner V2 versionado, reproducible y probado |
| Chrome CDP 9223 | El editor y el ImageBridge de noticias comparten navegador/sesión persistentes | Perfil y proceso Chrome V2 propios por trabajo, cerrados al completar |
| `TTiTTularesImageBridge.js` | Abre una conversación nueva dentro de un target fijo y reutilizado; no cierra normalmente el target/browser tras cada generación | Worker de imagen con Chrome/chat efímeros por noticia |
| `TTiTTularesWebImages.cjs` | Consume/inspecciona resultados en un navegador existente; no genera ni debe convertirse en generador | Consumidor de recepción V2 con interfaz de captura explícita, sin compartir sesión |
| `telegram/editorial-processing.json` y nombres heredados | Estado editorial compartido bajo un espacio histórico de Telegram | Cola nativa `v2/ttittulares/*`, sin dependencia de Telegram |
| `TTITTULARES_OUTBOX_V1` en issue #164 | Transporte mediante comentario de GitHub compartido con el legado | Outbox y aplicador V2 propios |

**Requisito clave del editor:** cada noticia se procesa en una conversación nueva e independiente; después de verificar la persistencia, se cierra esa conversación y el Chrome propio del trabajo. La misma regla aplica a las imágenes: chat nuevo de Images, generar, recuperar el original, asociar y verificar; después cerrar chat y Chrome. No se debe reutilizar una conversación siempre abierta para toda la cola ni un target fijo compartido.

Los dos consumidores deben ser independientes:
- el fallo o espera de una imagen no bloquea la investigación/redacción de otras noticias;
- una noticia ya guardada como READY no se vuelve a redactar por un fallo de imagen;
- los reintentos ambiguos no vuelven a enviar un prompt a ciegas;
- la asociación es idempotente por ID/revisión/comando/hash;
- cada worker cierra solo los procesos y targets que creó.

## 6. Fotografía de estado V1 en el corte auditado

Esta es una instantánea fechada de GitHub, no una afirmación de que Windows o todos los cron estén ejecutándose ahora:

| Dato | Valor en la instantánea |
|---|---:|
| Último radar | 16/11/2026 15:31:41 UTC |
| Fuentes generales sanas/configuradas | 19 / 19 |
| Noticias PROCESSING | 34 |
| Noticias READY/Listas | 13 |
| Incidencias PROBLEMATIC visibles en status | 0 |
| Elementos en la cola compacta | 34, todos PROCESSING |
| Elementos en prepared.json | 13 |
| prepared.json con ai_image_status=ready | 1 |

La rama de control `control/ttittulares-run-trigger-v2` contenía un índice de imágenes con cero jobs y `updated_at=2026-11-16T11:01:19Z`. Esa hora es anterior a la instantánea del status; no debe usarse para concluir que no hubo actividad posterior. La bandera local de pausa tampoco fue inspeccionada.

## 7. Decisiones de diseño para el nuevo sistema

### Reutilizar el conocimiento y los contratos
- Fuentes, umbral de cuatro familias, filtros, TTL, lógica de actualización material e identidad/antiduplicados.
- Prompt editorial, reglas de verificación, límite de caracteres, hashtags, política del remate y reescrituras acotadas.
- event_id, revision, parent_event_id y decisiones terminales.
- Separación texto/imagen; READY no espera a IA.
- Original de imagen validado y asociado por identidad, revisión, comando y SHA.
- Aprobación y publicación humanas; nada se publica por el mero hecho de terminar un job.

### Reconstruir
- Cola, modelo de trabajos, estados, leases, recuperación, trazabilidad, outbox y proyecciones bajo `v2/ttittulares/`.
- Runner editorial versionado: un trabajo = una noticia = un chat fresco = una captura persistida/verificada = cierre.
- Worker de imágenes independiente: un trabajo = una noticia/revisión = un chat fresco de ChatGPT Images = original = asociación/readback = cierre.
- Perfiles Chrome y procesos independientes de V1; nunca usar 9223/9234 ni la sesión persistente de TTiTTulares V1.
- Hemeroteca duradera separada de la cola READY mutable.
- Panel V2 para incidencias, reelaboración, progreso, imagen, asociación y decisión editorial.

### Decisiones que deben quedar centralizadas antes de activar producción
- Política única de encolado de imágenes post-READY, paralelismo, intervalo y reintentos.
- Número de workers editoriales e imagen simultáneos y límites globales de recursos.
- Cadencia de radar y de elaboración. La configuración V1 (`config.json`, README) y los cron actuales no usan exactamente los mismos minutos; fijar en V2 el calendario operativo verdadero sin copiar ambas señales.
- Modelo de archivo histórico y política de conservación de imágenes/originales.
- Punto exacto en que el usuario aprueba una noticia para publicación externa y cómo se registra el recibo.

## 8. Orden recomendado de construcción

1. **Contrato de datos V2:** definir IDs, revisiones, cola, historial, estados, decisiones, leases, outbox y recibos; no copiar las rutas legacy.
2. **Radar/ingesta:** portar primero el código probado de fuentes, familias, filtros, TTL, matching y material update, con fixtures y pruebas de regresión.
3. **Motor editorial efímero:** un trabajo por chat, independiente y cerrado, con JIT, persistencia y readback antes de continuar.
4. **Motor de imágenes efímero:** activado tras READY, independiente del editorial, con recuperación de originales y asociación SHA exacta.
5. **Interfaz V2:** reflejar estados, texto, imágenes e incidencias; permitir acciones humanas sin alterar V1.
6. **Paridad E2E y corte:** comparar noticias reales con V1, probar interrupciones/reinicios/duplicados y mantener V1 en paralelo hasta aprobar el nuevo flujo. Solo entonces migrar la entrada productiva a V2; retirar V1 en una fase reversible posterior.

## 9. Pendientes de verificación antes de copiar detalles internos

- Obtener una copia/versionado verificable de `C:\TTiTTulares\Ejecutar.js` si se necesita reutilizar alguna parte de su interacción con ChatGPT. No está en el repositorio `main`.
- Comprobar desde Windows el estado real de `V1-ImageGen-Paused.flag`, tareas programadas y listeners; no inferirlo desde GitHub.
- Comprobar ejecuciones reales de los cron y el ciclo completo noticia → READY; que un workflow esté definido no prueba que haya funcionado.
- Verificar una generación de imagen de noticia de extremo a extremo con original descargado, SHA, asociación en catálogo y visualización en web/APP.
- Aclarar/normalizar la cadencia V1 antes de fijar la cadencia de producción V2.

## 10. Archivos principales revisados

Los siguientes enlaces se fijan al commit de auditoría de V1 para evitar que cambios futuros alteren la referencia:

- [README y mapa funcional TTiTTulares](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/README.md)
- [Contrato editorial](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/editorial-run-prompt.md)
- [Configuración TTiTTulares](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/config.json)
- [Radar de fuentes](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/telegram/radar_no_d1.py)
- [Selección automática y deduplicación](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/auto_queue.py)
- [Memoria de noticias tratadas](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/treated_news.py)
- [Aplicador de outbox y READY](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/ttittulares/apply_editorial_outbox.py)
- [Listener local](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/windows/TTiTTularesDedicatedListener.ps1)
- [ImageBridge de noticias](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/windows/TTiTTularesImageBridge.js)
- [Consumidor de originales de imagen](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/windows/TTiTTularesWebImages.cjs)
- [Asociación original a catálogo](https://github.com/fabricelop/europapress-rss/blob/108ca043d5a288b72dfa654745199cae49b64696/.github/workflows/ttittulares-original-image-association.yml)

---

**Regla de seguridad del proyecto:** todo este documento es una especificación de diseño para V2. No autoriza a modificar V1, instalar listeners, cerrar Chrome, reencolar noticias, generar imágenes, aprobar imágenes ni publicar en X/Instagram/Telegram. V1 permanece intacto durante la construcción y validación.
