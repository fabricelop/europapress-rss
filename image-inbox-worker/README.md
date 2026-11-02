# TTActualidad — Inbox privado de imágenes

**SIN desplegar.** Implementación preparatoria que no modifica Sites, la APP instalada ni los consumidores Windows. Requiere cuentas, recursos y controles de acceso de Cloudflare y la conexión con build59+.

- `ORIGINALS`: R2 **privado**, sin dominio público, sin `r2.dev`. Conserva los PNG originales.
- `DB`: D1 con migración `0001_images.sql`, todas las decisiones atómicas.
- `INGEST_TOKEN`: secreto robusto (>=32 caracteres), independiente de GitHub, solo en receptor de originales del PC.
- `APP_GITHUB_USER_ID`: ID numérico de GitHub del editor autorizado, verificado contra `/user` de GitHub con el OAuth token de la APP. **No se guarda el token**.
- `wrangler.jsonc`: `workers_dev:false` y D1 `REPLACE_WITH_REAL_D1_ID` para impedir publicar accidentalmente. Se debe configurar una ruta privada HTTPS aprobada antes de instalar APP; sin un endpoint real la UI muestra no configurado.

API:
- `POST /v1/images/ingest`: ingestión de multipart, campos `metadata` JSON e `image` PNG, cabecera `X-TT-Ingest-Key`; identidad con `project,editorialId,revision,episodeFingerprint,commandId,rasterSHA256`, además `title,editorialText`; hash SHA calculado sobre **bytes reales**, no sobre vista previa. Devuelve ID hash o estado existente; no recrea rechazadas.
- `GET /v1/images`: solo autorizado GitHub, devuelve pendientes (sin URL pública).
- `GET /v1/images/:id/original`: solo autorizado GitHub, imagen PNG R2, Cache-Control privado/no-store.
- `POST /v1/images/:id/decision`: editor GitHub; body `{ "action":"approve|reject", "expectedIdentity":{...} }`; transición única e idempotente con comparación exacta.

**Garantía:** `approve` solo marca `approved_awaiting_publication`. No hay rutas públicas ni código de publicación en este Worker. La publicación requiere un publicador independiente que valide nuevamente episodio/revisión/hash y confirme APP+Sites. El Worker **no considera publicada una imagen al aprobarla**, porque aún no está integrado con los dos catálogos. `reject` solo saca el candidato de la bandeja; original intacto.

**Antes de producción:** verificar autorización al GitHub App y permisos, proteger endpoints de ingestión, conectarlo al receptor del PC, completar verificación contra fuentes editoriales de main antes de publicar, integración real con el Sites v38 y la app, y pruebas E2E con PNG real. Mantener la pausa de PR270 hasta el final.

## PC — preparación del traslado privado (NO conectado a los consumidores vivos)

`tools/send-original.mjs` es un importador **opt-in**, sin instalación, reinicio ni tarea programada. Solo lee el PNG existente y su ficha/identidad JSON, comprueba SHA-256 y entrega por HTTPS al buzón; no escribe web ni catálogos. Requiere el endpoint seguro y el secreto cargados en variables de entorno del PC (no pasarlos en línea de comandos).

`node image-inbox-worker/tools/send-original.mjs --image ORIGINAL.png --metadata FICHA.json`

La captura de Images y la comprobación de episodio siguen pendientes; este comando no las sustituye. No ejecutar con datos inventados ni cambiar los consumidores mientras no se hayan validado los procesos activos.