# Integración mínima del ingreso manual en TTActualidad Sites

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
- 409 ante ficha retirada, texto/revisión obsoletos o conflicto de imagen ya aprobada; no devolver un 503 genérico para estas situaciones.
- La fuente exacta de TTendencias es `trends/telegram-manual-explained.json`, junto a `trends/mobile-decisions.json`. Seguir la regla de Listas iOS: último ID/revisión explicado, fecha de las últimas 48 h, grupo líder, cierres no posteriores a una nueva explicación.
- Para TTiTTulares usar `ttittulares/prepared.json` (texto del tuit si existe, en caso contrario explicación/resumen factual) y `ttittulares/decisions.json`.
- 503 únicamente por dependencia/lectura/almacenamiento temporalmente no disponible, con código de error corto y correlationId. No incluir tokens ni PNG en registros.

## Publicación

Tras el ingreso la app usa la ruta **ya existente** `POST /api/image-inbox/v1/images/{id}/decision` con `action:"approve"` y `expectedIdentity` exacta. No cambiarla ni crear una aprobación implícita en el upload. La respuesta `published` requiere **readback verificable web y app** (`appVerified:true`, `sitesVerified:true`) del mismo SHA. Si queda pendiente, devolver `approved_awaiting_publication` y conservar original y decisión de forma idempotente.

## Prueba de aceptación obligatoria en el Site REAL

1. Desde iPhone autenticado abrir ficha vigente, pegar un PNG, tocar **Subir y aprobar**.
2. Confirmar 201/200 y una única entrada privada por idempotencia.
3. Aprobar; verificar archivo público y catálogo APP por ID+revisión+SHA; si no está en ambos, no declarar éxito.
4. Reintentar mismo PNG y comprobar una única imagen/publicación, sin regeneración.
5. Repetir con ficha retirada: 409 explícito; sin modificación pública.
6. Comprobar que «Aprobar/Rechazar» existente, imágenes automáticas, X y editorial no han variado.

## Evidencia de diagnóstico remoto (04/11/2026)

Run GitHub Actions 41901343516: sin OAuth, `POST /manual`, `POST /ruta-inexistente` y ambos `OPTIONS` devuelven **todos 401** por la capa de autenticación general. Ese 401 **NO verifica** la existencia de la ruta; la captura autenticada del iPhone build69 muestra **404 NOT_FOUND**. Requiere acceso a la versión actual del backend Site y prueba autenticada para descartar que siga faltando el handler. No distribuir otra IPA como reparación del 404 sin haber probado el endpoint.
