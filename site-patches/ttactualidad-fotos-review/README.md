# TT Fotos · aprobación privada desde web — adaptación preparada, NO desplegada

Estado (2026-11-11): la vista `index.html` de este directorio es código funcional **solo cuando el Site privado implementa el contrato de API inferior**. No se debe servir como si funcionase desde GitHub Pages, ni enlazarla como operativa antes de que los endpoints devuelvan respuestas y recibos reales. La bandeja original no se sustituye ni modifica su interfaz.

## Arquitectura

- Monitor público independiente: `docs/fotos/index.html` en GitHub Pages. Sigue los encargos de `control/ttittulares-run-trigger-v2` y `control/ttendencias-run-trigger`, más catálogos públicos, sin permisos de escritura.
- Vista de decisiones: **ruta nueva del mismo origen de TTActualidad** (por ejemplo `/fotos` del Site `ttactualidad.rainyraven22.chatgpt.site`), que use la sesión ya autenticada en ese Site. Es una página de revisión independiente, aunque su API sea la misma que la de la bandeja.
- Fuente privada autoritativa: imagen pendiente y recibo con identidad exacta `project + editorialId + revision + commandId + rasterSHA256 + receiptId`. No inferir asociaciones por título, proximidad temporal o nombre de archivo. No usar el `site-ai-images.json` público para aprobar: ese catálogo no prueba la recepción privada.
- Aplicador: debe invocar el **mismo servicio de decisiones** que invoca la bandeja de TTActualidad. No se implementa aquí porque el código/contrato privado de ese servicio no está expuesto por el conector disponible. No crear registros ficticios en GitHub ni aprobar en una base paralela.

## Contrato propuesto entre la nueva vista y el Site privado

Los endpoints siguientes son una **propuesta de integración**, no afirmaciones de que ya existan.

### GET /api/image-inbox/v1/review?limit=100

Requiere sesión del editor, autorización específica de lectura y protección `no-store`. Responder:

```json
{
  "ok": true,
  "schema": "tt-image-review-v1",
  "csrf_token": "<nonce de sesión no reutilizable en otras sesiones>",
  "items": [
    {
      "receipt_id": "<identificador estable del recibo privado>",
      "command_id": "<orden exacta de ImageGen>",
      "editorial_id": "<ID de noticia o tendencia>",
      "project": "ttendencias",
      "revision": 0,
      "raster_sha256": "<SHA-256 hexadecimal del PNG original>",
      "status": "pending",
      "title": "<título desde el registro editorial asociado>",
      "received_at": "2026-11-11T14:00:00Z",
      "image_url": "/api/image-inbox/v1/review/<receipt_id>/preview"
    }
  ]
}
```

La vista previa es una URL **mismo origen y autenticada**, `private`, con `Cache-Control: private, no-store`; validación de sesión por solicitud; ninguna URL pública permanente ni token de acceso en query. La lista y las vistas previas no devuelven elementos ajenos al usuario.

### POST /api/image-inbox/v1/review/decision

Headers `Content-Type: application/json`, `X-TT-CSRF`, `Idempotency-Key`; cookies de sesión del Site. Solicitud:

```json
{
  "receipt_id": "...",
  "project": "ttendencias",
  "editorial_id": "...",
  "command_id": "...",
  "revision": 0,
  "raster_sha256": "<hash>",
  "expected_status": "pending",
  "action": "approve",
  "idempotency_key": "web-<UUID>"
}
```

`action` admite exclusivamente `approve` o `reject`; `reason` opcional limitado a 500 caracteres para rechazo. El backend **debe** volver a cargar la fila privada, comprobar permiso del usuario, coincidencia exacta de todos los campos e integridad del PNG, estado pendiente, que el episodio no cambió de revisión y que no existe otra decisión. La escritura de la decisión y del recibo de idempotencia debe ser atómica. Dos reintentos idénticos con la misma clave dan el mismo resultado; una clave reutilizada para otro contenido da conflicto. No permitir CORS arbitrario, CSRF, inyección de ID, carga de URL externa o acceso anónimo.

Solo tras confirmar la decisión real devolver:

```json
{
  "ok": true,
  "schema": "tt-image-review-v1",
  "receipt_id": "...",
  "command_id": "...",
  "editorial_id": "...",
  "revision": 0,
  "raster_sha256": "<hash>",
  "status": "approved_awaiting_publication"
}
```

En rechazo, `status=rejected`. Si el aplicador existente ya completó la asociación, `status=published` es válido tras aprobación, nunca equivale a publicar en X o Instagram. Un error debe dejar el expediente pendiente o mostrar el resultado definitivo que exista, no devolver éxito optimista. Los códigos 401/403, 409 por revisión/cambio de estado y 429 por límite se deben respetar. No realizar publicación social automática. No regenerar imágenes.

## Requisitos para instalar en el Site

1. Localizar el controlador **real** que usa actualmente «Aprobar/Rechazar» dentro de la bandeja de TTActualidad (incluidos su almacenamiento privado, auditoría, idempotencia y lógica de publicación de imagen en Site/app).
2. Crear solo dos rutas nuevas de lectura/decisión que **deleguen** en ese mismo controlador. No duplicar la base de datos ni introducir otra fuente de verdad. Reutilizar autenticación y CSRF propios del Site.
3. Exponer esta `index.html` en una **ruta nueva** `/fotos`, sin sustituir páginas, componentes, ni el flujo original de la bandeja.
4. Probar dos imágenes reales en estado pendiente, una por proyecto: observar recibo privado, previsualización, aprobar una, rechazar otra; verificar estado reflejado en la bandeja original y que no se ha publicado nada automáticamente en X/Instagram.
5. Repetir los mismos POST y comprobar idempotencia; enviar revisión y hash incorrectos y exigir 409 sin cambio; probar sesión expirada y exigir 401/403. Verificar que no aparece ningún token o PNG privado en GitHub ni en el HTML.
6. Solo después de esos tests, añadir desde el monitor público de GitHub Pages un enlace a `/fotos`. No habilitar un POST cross-origin desde GitHub Pages.

## Limitación actual

El conector TTActualidad disponible en este chat **puede recibir PNGs para revisión**, consultar Top 30 e imágenes vinculadas, pero **no permite aprobar ni rechazar**. No existe en el repositorio una implementación verificable del aplicador privado de la bandeja. Por tanto, ni el endpoint anterior ni la ruta `/fotos` han sido instalados en el Site y no cabe afirmar que las decisiones web estén ya operativas.
