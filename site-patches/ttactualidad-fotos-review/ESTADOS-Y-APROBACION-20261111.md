# TT Fotos: un único panel de imágenes y decisiones — 11/11/2026

## Objetivo actual del editor

El objetivo es **una web independiente** que permita ver **todas las noticias y tendencias con imagen pendiente o en proceso** e identificar exactamente el paso en que está cada fotografía, desde la ficha editorial hasta su aprobación/rechazo. Debe poder **aprobar y rechazar** desde esta misma web, con la **misma autoridad** y efecto que desde la bandeja actual del iPhone. **No modificar ni reemplazar** la interfaz de bandeja original de la APP, ni regenerar imágenes, ni publicar X/Instagram automáticamente.

La web no puede limitarse a los jobs indexados porque esos índices pueden contener solamente el encargo más reciente. Cruce obligatorio por (project, editorial_id, revision, command_id), no por título. Para fichas todavía sin command_id, mantener (project, editorial_id, revision).

## Fuentes autoritativas para cada fase

| Fase que debe mostrar | Fuente de verdad | Interpretación estricta |
|---|---|---|
| Noticia lista, sin encargo localizado | `main/ttittulares/prepared.json`, con `tweet.text`, revisión y `with_image` elegible, cruzado con job individual | «Pendiente de encargo / sin trabajo localizado». **No** deducir que la foto no existe |
| Tendencia explicada, sin encargo localizado | `main/trends/site-top30-current.json` para Top 30 actual; historial editorial para salidas del Top 30 si disponible; estado de job por ID | «Pendiente de encargo / sin trabajo localizado» |
| Solicitud de IA | `control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/{id}.json` o `control/ttendencias-run-trigger/trends/image-runs/jobs/{id}.json` y sus índices | `REQUESTED` = orden en cola; `RUNNING/composer_ready` = preparación, **no** envío; `LAUNCHED/pc_launched` = prompt enviado, **no** PNG terminado |
| Imagen generada o capturada | Original PNG con procedencia del comando exacto, byte SHA-256 y `command_id`, por receptor local seguro o almacenamiento privado | No inferir generación por `LAUNCHED`; la ausencia de imagen pública no es ausencia del raster |
| Error / incidencia | Campo `status=ERROR/FAILED`, `phase`, `error`, `web_image` del trabajo individual o fallo de receptor correlacionado por `command_id` | Mostrar motivo, fase y hora; un ERROR tras envío puede coexistir con PNG; distinguir errores antiguos de estado actual |
| Recibida en bandeja | Recibo local en `C:\TTiTTulares\image-approval-receipts\<command_id>.json` o el registro privado R2/D1 | El recibo PC prueba entrega en ese momento; **no** que el candidato siga pendiente actualmente |
| **Lista para aprobar/rechazar ahora** | **GET autenticado del Site** `/api/image-inbox/v1/images` devuelve candidatura `pending` actual con identidad y original privado recuperable | Mostrar botones solo si original PNG descargado y `SHA-256 == identity.rasterSHA256`. Sin sesión/autorización, estado `NO VERIFICABLE` |
| Aprobada pendiente de publicación | Respuesta autentificada `approved_awaiting_publication` o estado persistido del backend | No declarar éxito completo ni retirar definitivamente como publicada |
| Publicada y visible | Respuesta y lectura backend `published`, `appVerified=true`, `sitesVerified=true` | **Publicación de imagen APP+Site**, no tuit en X ni publicación en Instagram |
| Rechazada | Decisión backend `rejected`, identidad exacta y recibo del servicio | Retirar del pendiente, conservar original y registro. La lista de pendientes por sí sola no acredita por qué desapareció |

### Rutas privadas reales documentadas, NO inventadas

Fuente: memoria maestra TTActualidad `libfile_c244fcbdb29c8191a1d37f82a7ba3aa5` edición 174, §§35/64 y v86, más el código de `ios/ttactualidad/TTActualidad/ImageApprovalInbox.swift` y `GitHubEditor.swift`.

- `GET https://ttactualidad.rainyraven22.chatgpt.site/api/image-inbox/v1/images` — `{"items":[{"id":"<hex64>","identity":{"project":"ttendencias","editorialId":"...","revision":0,"episodeFingerprint":"<hex64>","commandId":"...","rasterSHA256":"<hex64>"},"title":"...","editorialText":"...","createdAt":"..."}]}`.
- `GET /api/image-inbox/v1/images/{id}/original` — PNG privado cuyo SHA-256 se valida antes de mostrar acciones.
- `POST /api/image-inbox/v1/images/{id}/decision` — cuerpo **exacto** `{"action":"approve"|"reject","expectedIdentity": { ...identity devuelta por la lista... }}`.
- Solo `published + appVerified + sitesVerified` acredita aprobación publicada. `approved_awaiting_publication` obliga a seguir comprobando. `rejected` acredita rechazo.

**Autenticación:** la APP envía un Bearer OAuth GitHub del editor exclusivamente a ese Site; **no** poner token personal, OAuth de GitHub, secretos de ingestión ni URL firmada en el JavaScript público/GitHub Pages. Al implementar `/fotos` dentro del **mismo Site original**, habilitar una sesión web segura del editor que dé al controlador privado la misma autorización que a la APP, con protección CSRF, cookies seguras, control de Origin y no-cache. Si no existe todavía un flujo de login navegador autorizado, implementarlo/validarlo **del lado del Site**, nunca aceptar simplemente una cookie anónima.

## UX de la página completa

Un único panel móvil con filtros `Todos | Noticias | Tendencias`; contadores verificables `sin encargo localizado / solicitadas / preparando / ChatGPT enviado / error / original capturado / recibida / pendiente de decisión / aprobada pendiente publicación / publicada / rechazada`. Buscador título/ID, hora real por fase, causa del fallo y botón de ver registro exacto. Tarjeta con titular o nombre de tendencia, remate o texto, miniatura ORIGINAL privada cuando está disponible, historial cronológico de pasos y acción:

- Si no está en bandeja: no ofrecer aprobar/rechazar; detallar siguiente paso y último error con evidencia.
- Si está en bandeja `pending`: permitir ver original, confirmar `Aprobar` o `Rechazar`, enviar decisión al **mismo** endpoint privado con `expectedIdentity` exacto; asegurar POST no duplicado.
- Después: consultar backend y mostrar `published`, `rejected` o `approved_awaiting_publication` según respuesta **y** recibo. En timeout/503 mantener el expediente con estado no confirmado y no reintentar por su cuenta.
- La APP debe reflejar la misma decisión cuando vuelva a consultar; no tener dos fuentes de verdad. No cambiar la pantalla existente.

Historial más allá de Top 30/Listas: **no** confundir la ausencia del índice actual con una conclusión negativa; la vista privada deberá resolver los jobs y recibos históricos por IDs persistidos. No escanear 1000+ archivos en cada vista; usar índice de lectura compacto de solo telemetría con escritura transaccional/idempotente sin modificar los productores. No sustituir el motor de generación ni añadir servicios de pago.

## Archivos ya creados

- Monitor público original: `docs/fotos/index.html`.
- Vista diagnóstica de estados (GitHub Pages, solo lectura): `docs/fotos/estado.html`. Cruza READY, Top 30 explicadas, índice y trabajos individuales, catálogos públicos y JSON local opcional. **No puede acreditar el pending privado actual**.
- Vista de revisión privada preparada: `site-patches/ttactualidad-fotos-review/index.html`. Adaptada a GET `/v1/images`, GET `/original`, POST `/decision` con `action/expectedIdentity`, pero **no desplegada**; debe integrarse con sesión web de editor en el Site real.
- **No** publicar la vista privada como código autónomo de decisión en GitHub Pages. El navegador público no puede acceder de forma segura al backend OAuth privado.

## Test de aceptación

1. Noticia READY sin job: aparece «sin encargo localizado»; no como «fallida». Tendencia explicada igual.
2. Noticia REQUESTED y tendencia RUNNING/composer_ready: etiquetas distintas; no aparecen como imagen terminada.
3. Trabajo LAUNCHED pero PNG no encontrado: «prompt enviado, imagen sin confirmar».
4. Trabajo ERROR: ver motivo/fecha exactos; no descartar imagen existente si hay recibo auténtico.
5. Original confirmado por SHA, recibido en R2/D1: pasa a pendiente en bandeja privada; botón disponible tras verificar bytes.
6. Aprobar una imagen de noticia: backend devuelve published y appVerified/sitesVerified verdaderos; imagen visible en ambas superficies y retirada de pendientes.
7. Rechazar una imagen de tendencia: rechazo confirmado por backend, original privado conservado y tarjeta desaparece de pendientes en APP y web.
8. 401/403, revisión obsoleta, hash incorrecto, 503, timeout y doble pulsación: ninguno produce éxito aparente, duplicación ni publicación accidental.
9. Todo sin romper generador, app nativa, bandeja original, Site público ni X/Instagram. Verificar en iPhone y navegador, con hora y recibos.

**Estado de entrega:** archivos del monitor y prototipo de revisión preparados en GitHub; todavía falta integrar la nueva ruta web autenticada en el **Site Next.js/Worker productivo** y realizar pruebas E2E. La herramienta TTActualidad de esta conversación ofrece ingestión/consulta parcial, pero NO un editor del backend privado.
