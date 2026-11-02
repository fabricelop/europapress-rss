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

## Revalidación editorial y entrega privada al publicador (extensión de seguridad)

**No hay publicación automática.** El servicio solo recibe, lista, decide y permite recuperar
privadamente el PNG que haya sido aprobado. No modifica las fichas, los catálogos ni Sites.

La huella `episodeFingerprint` se calcula exclusivamente como
`SHA256(UTF8(JSON.stringify({project, editorialId, revision, editorialText})))`.
El importador calcula la huella y el SHA-256 del PNG a partir de los bytes reales.
No se admite una huella declarada que no coincida. `editorialText` debe coincidir
exactamente con el texto canónico vigente de la noticia (`tweet.text` en
`ttittulares/prepared.json`) o tendencia (`explanation` en `trends/prepared.json`),
incluidos saltos de línea, hashtags y remate.

Antes de **Aprobar** el servicio lee el documento preparado desde la API GitHub
(ref `main`, sin caché), con el OAuth ya autorizado del editor. Comprueba ID,
revisión, unicidad y texto completo. Si hay cambio, desaparición, documento
ambiguo, falta de red o error de lectura, **no aprueba**. **Rechazar** no requiere
que GitHub esté accesible, porque solo retira la tarjeta y conserva el PNG.

El publicador futuro debe usar un secreto independiente `PUBLISH_TOKEN` (>=32
caracteres) almacenado como *Worker Secret*, y el servicio requiere además
`GITHUB_SOURCE_READ_TOKEN` (GitHub con lectura de Contents, almacenado SOLO como
Worker Secret) para revalidar antes de entregar bytes:

- `GET /v1/publications`: `X-TT-Publish-Key`, relación privada de imágenes
  `approved_awaiting_publication`; no incluye URL pública ni contenido binario.
- `GET /v1/publications/{id}/original`: misma cabecera; solo imágenes aprobadas.
  Relee GitHub `main` **otra vez**, compara el texto/revisión/identidad, recupera
  el raster de R2, verifica SHA-256 y devuelve el PNG original privado y la
  cabecera `X-Original-SHA256`. Si el episodio cambió o el original no coincide,
  devuelve un error y no entrega nada.

Es un **traspaso privado**, no una señal de publicación exitosa: aún falta un
publicador integrado que efectúe la vinculación en APP y Sites, consulte ambos
catálogos con identidades exactas y registre recibos auténticos de cada destino.
Una comprobación final del texto/revisión debe realizarse inmediatamente antes
de la escritura pública (el contenido puede cambiar después del traspaso).
No marcar `published` sin verificar ambos destinos. No usar `PUBLISH_TOKEN`
para ingestión ni para iniciar sesión en la APP. Los secretos no se incluyen en
el repositorio ni se colocan en `wrangler.jsonc`.

Hasta que haya recursos R2/D1 reales, secretos, endpoint HTTPS, receptor del PC,
publicador de Sites y nueva IPA configurada: **bandeja no operativa**.


## Prueba de integración del publicador (SIN escritores reales)

`tools/publish-approved-once.mjs` implementa el **orden verificable** de una
publicación aprobada, con dependencias explícitamente inyectadas. No contiene
adaptadores reales ni credenciales; no se ejecuta en producción por sí solo:

1. Obtener la aprobación exacta por `id` derivado de la identidad completa y los
   bytes del PNG original privado. Comprobar el SHA-256 antes de cualquier escritura.
2. Leer el documento editorial vigente, publicar en la ficha exacta de la APP
   mediante un adaptador autenticado, leer la imagen en APP y comprobar los bytes.
3. Volver a verificar la ficha editorial, publicar mediante el adaptador Sites,
   leer la ficha e imagen en Sites, comprobar de nuevo los bytes y el texto.
4. Solo después de verificar **ambos** destinos y el texto actual, emitir un
   recibo auditable de éxito. Si falla uno, jamás declarar publicación completa;
   conservar el estado para reintento idempotente y reparación manual.

Pruebas de regresión cubren la ausencia de aprobación, cambio de episodio,
identidad inconsistente, raster adulterado, fallo de lectura en APP/Sites y
cambio editorial en medio de la operación. Los adaptadores reales y el almacén
de recibos con readback siguen pendientes: **no afirmar que la aprobación ya
sube imágenes a APP/Sites**.