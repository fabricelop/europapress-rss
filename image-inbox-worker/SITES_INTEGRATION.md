# Integración mínima del ingreso manual en TTActualidad Sites

> **Decisión editorial 05/11/2026:** «Subir y aprobar» existe **solo en la APP nativa iPhone**. No añadir botón, panel ni aprobación al Site. El Site es el destino de publicación y el visor web; debe mantener el mismo sistema de imágenes aprobadas que ya funciona.

**Estado: NO DESPLEGADO EN SITES.** El código del backend del Site canónico no está en este repositorio. Este contrato solo es una guía de integración, no un reemplazo de producción ni una orden para levantar otro panel o Worker.

## Ruta necesaria en la instalación que ya existe

`POST https://ttactualidad.rainyraven22.chatgpt.site/api/image-inbox/v1/images/manual`

La app nativa 0.4.57 build69 llama a esta ruta con el mismo OAuth GitHub del editor que utiliza la bandeja privada. Es `multipart/form-data` con:

- `metadata`: JSON con `project` (`ttendencias` o `ttittulares`), `editorialId`, `revision`, `title`, `editorialText`, `commandId` (estable por episodio+raster) y `rasterSHA256` del PNG real.
- `image`: original normalizado PNG, máximo 8 MB; nunca hay que subir capturas de pantalla de la ficha ni imágenes de identidad aproximada.

Responder 201 al crear, 200 al reintentar el mismo archivo/episodio, con:
`{"id":"<SHA256 de identidad>","state":"pending|approved_awaiting_publication|published","identity":{"project":"...","editorialId":"...","revision":0,"episodeFingerprint":"...","commandId":"...","rasterSHA256":"..."}}`.

Utilizar **los recursos PRIVADOS ya conectados a la bandeja actual** (almacenamiento original y registros de candidatos), la misma validación OAuth y el mismo publicador en dos destinos. Nunca migrar D1/R2/KV, resetear fichas, cambiar el botón Aprobar/Rechazar o crear un segundo estado editorial. El módulo de referencia `src/index.mjs` aporta solo la lógica de entrada y `src/editorial-truth.mjs` el control de identidad; su `wrangler.jsonc` NO contiene los identificadores productivos.

## Autorización y verificación editorial

- 401 si la sesión GitHub no identifica al editor autorizado; **validar antes de consumir o almacenar los bytes**.
- 413/415 si el archivo excede tamaño/dimensiones o no es PNG real; verificar SHA-256 calculado sobre los bytes antes de guardar.
- 409 solo ante **ID/revisión/texto/episodio realmente inexistente u obsoleto**, conflicto de imagen aprobada o hash incorrecto. Una ficha histórica publicada, retirada de Listas o fuera del Top30 sigue siendo ilustrable por aprobación expresa del editor; no devolver 409 por su estado de Listas. Nunca reabrirla ni modificar su decisión editorial.
- Fuente de TTendencias: `trends/telegram-manual-explained.json` como **historial de episodios por ID + revisión + texto + fecha exactos**. `trends/mobile-decisions.json` gobierna las acciones editoriales, pero no debe bloquear la ilustración de un episodio histórico ya publicado o retirado. **No** aplicar la ventana de 48 horas ni la regla del grupo líder propia de *Listas*. Se exige fecha editorial original y verificación frente a GitHub `main`, sin vincular por nombre, posición o tema similar.
- Para TTiTTulares usar `ttittulares/prepared.json` (texto del tuit si existe, en caso contrario explicación/resumen factual) y `ttittulares/decisions.json`.
- 503 únicamente por dependencia/lectura/almacenamiento temporalmente no disponible, con código de error corto y correlationId. No incluir tokens ni PNG en registros.

## Publicación

Una pulsación del editor en **«Subir y aprobar» de la APP** encadena dos operaciones en el **backend ya existente**: (1) ingreso privado idempotente del PNG y (2) llamada a la ruta actual `POST /api/image-inbox/v1/images/{id}/decision` con `action:"approve"` y `expectedIdentity` exacta. No cambiar esa ruta, no aprobar al recibir el upload sin el acto de la APP, no añadir controles al Site ni crear publicador paralelo. El servidor conserva el original y publica por el circuito que ya emite los recibos de APP + Site; el cliente solo muestra `published` tras **readback verificable en ambos destinos** (`appVerified:true`, `sitesVerified:true`) del mismo SHA. Si queda pendiente, devolver `approved_awaiting_publication`; tras timeout reconsultar el estado antes de reintentar. La app debe actualizar su ficha local por ID/revisión/episodio sin depender de descargar todas las listas.

## Prueba de aceptación obligatoria en el Site REAL

1. **Solo desde APP iPhone**, abrir ficha de tendencia o noticia (en Listas o histórica), seleccionar PNG, tocar **Subir y aprobar** una sola vez; comprobar que no se añade ningún botón equivalente al Site.
2. Confirmar 201/200 y una única entrada privada por idempotencia.
3. Comprobar que esa pulsación encadena la decisión de aprobación, el mismo publicador oficial y el readback público; verificar archivo original y catálogo APP por ID+revisión+texto+fecha+SHA. Si uno falta, mostrar pendiente/error y no declarar éxito.
4. Reintentar mismo PNG y comprobar una única imagen/publicación, sin regeneración.
5. Repetir con una ficha histórica ya retirada/publicada o fuera del Top30: **debe aceptar su imagen**, siempre que ID, revisión, texto, fecha y SHA coincidan; no volver a Listas. Comprobar por separado que una revisión/episodio verdaderamente distinto devuelve 409.
6. Recuperar **sin resubida** los originales de Valverde (`e470cdee843b` r0, SHA `8f0947282e2fe3e8408f84b7342c8cc04f8b5a492219a3880f73004f468aff05`) y Bellingham (`3a77ac385fa9` r0, SHA `67be1cda00f8ec8dc4ec32fa0d512361a7ac9c0e45a1aac9f8aab405be568ccf`) ya conservados en GitHub. Asociarlos al mismo registro de aprobación/publicación sin inventar estado `sitesVerified`. Mostrar cada foto en el contenido **expandido** del Site Next.js, también la ficha histórica fuera del Top30; aceptar únicamente URL/raster de origen verificado, sin alterar la portada.
7. Comprobar que la bandeja «Aprobar/Rechazar», imágenes automáticas, X, Instagram, portada, relaciones, Live Activity y decisiones editoriales no han variado.

## Evidencia de diagnóstico remoto (04/11/2026)

Run GitHub Actions 41901343516: sin OAuth, `POST /manual`, `POST /ruta-inexistente` y ambos `OPTIONS` devuelven **todos 401** por la capa de autenticación general. Ese 401 **NO verifica** la existencia de la ruta; la captura autenticada del iPhone build69 muestra **404 NOT_FOUND**. Requiere acceso a la versión actual del backend Site y prueba autenticada para descartar que siga faltando el handler. No distribuir otra IPA como reparación del 404 sin haber probado el endpoint.
