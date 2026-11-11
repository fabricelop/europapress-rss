# TT Fotos — Recuperar directamente ChatGPT Imágenes a la ficha correcta (11/11/2026)

## Requisito autoritativo del editor (sustituye importación Windows V1/V2/V3)

> «Lo que quiero es recuperar directamente las imágenes desde la página chatgpt Images no a mi pc, sino a la ficha correspondiente».

**NO pedir descargas manuales de PNG, NO usar C:\\TTiTTulares\\TTFotos-Importar, NO limitar la recuperación a cachés locales, NO cambiar la bandeja privada del iPhone.**

Objetivo: leer las imágenes existentes mediante una **sesión autenticada y autorizada del editor en ChatGPT Imágenes** y transferir su contenido binario **directamente a almacenamiento privado del TTActualidad Site** con asociación verificable a la noticia/tendencia y revisión. El PC personal no es destino ni almacén intermedio. No publicar imágenes ni crear nuevas.

El monitor actual en `windows/TTFotosRescate.cjs` y `windows/TTFotosRescatePanel.html` ES UN INVENTARIO LOCAL, **no** el producto final solicitado. No recomendar instalar más versiones de ese monitor como solución a este requisito.

## Hechos verificados y límites

- ChatGPT Imágenes contiene automáticamente las imágenes generadas, según <https://help.openai.com/es-es/articles/11084440-images-in-chatgpt>.
- La ayuda pública describe visualizar, copiar, guardar y compartir imágenes; **no documenta una API pública de enumeración/exportación masiva de la colección**. No inventar endpoint ni afirmar que el listado automático o la descarga son posibles por API.
- Desde este chat no existe acceso a la sesión autenticada de ChatGPT Imágenes ni a la consola/despliegue del proyecto Site. No afirmar que una exportación o migración de imágenes privadas ya se ha ejecutado.
- Site real: `https://ttactualidad.rainyraven22.chatgpt.site`; proyecto interno `appgprj_6ae4dcf7d7488191a574e5b649e67370`; R2 privado y D1 documentados en memoria maestra v179. **Confirmar bindings/esquemas reales antes de editar el Site.**
- La bandeja APP usa `/api/image-inbox/v1/images`, `/original`, `/decision` y un ingest separado. **Prohibido reutilizar su ingest/decision/approval como destino de la recuperación**: el editor quiere el nuevo estado en la ficha del monitor, no en iPhone.

## Arquitectura que debe implementarse

```
ChatGPT Imágenes (sesión de editor)
   |
   | Obtener originales de forma autorizada en el navegador/sesión,
   | no guardar en disco local; no usar URLs temporales de ChatGPT como persistencia.
   v
TTActualidad Site (editor OAuth autenticado + CSRF + tamaño/tipo + SHA-256)
   | -- R2 privado: tt-fotos/originals/{SHA256}.png (nunca pública)
   | -- D1: imágenes, correspondencias editoriales, histórico y errores
   v
Monitor TT Fotos remoto /fotos
   | -- Ficha de noticia/tendencia e imagen incorporada
   | -- Indicar origen ChatGPT Imágenes, SHA, conversación, commandId, confianza
   | -- Versión reciente puede ser la visible, anteriores se preservan
   '-- Sin ninguna llamada a bandeja iPhone, publicación ni ImageGen
```

No se permite «hotlinking» de `blob:`, `data:` o CDN privado/caducable de ChatGPT como imagen final. El original debe transferirse por HTTPS en bytes a R2 privado y tener recibo persistente **del propio monitor**.

### API separada en el Site (nombres son propuesta, NO endpoints existentes)

- `GET /api/tt-fotos/v1/jobs?since=2026-11-10`: consultar todos los encargos candidatos de GitHub, por **commandId y revisión**, no solo índice de última imagen.
- `POST /api/tt-fotos/v1/assets`: editor OAuth autorizado, CSRF, cuerpo PNG o multipart, SHA256 calculado en servidor, límite <=8 MiB, original durable en R2; devuelve assetId, sha y estado independiente. No tocar `image-inbox`.
- `POST /api/tt-fotos/v1/matches`: asociar `assetId` con `(project, editorialId, revision, commandId)`; exigir evidencia de origen. Si evidencia de contexto exacta, asociar automáticamente; si ambigua, `needs_review` sin selección silenciosa.
- `GET /api/tt-fotos/v1/assets/:id/original`: solo editor autenticado; servir bytes y evitar cachés compartidas.
- `GET /api/tt-fotos/v1/status`: contadores separados `discovered`, `raster_captured`, `associated`, `needs_review`, `failed` y `missing`. `LAUNCHED` no es raster.
- Las operaciones deben registrar `eventId`, fecha, `rasterSHA256`, `sourceConversationUrl`, `commandId`, `editorialId`, `revision`, estado, errores; no registrar cookies, URLs firmadas, tokens ni contenido de sesión en logs.

### Fuente para la asociación

- Primero, `commandId` exacto en conversación origen: `tt-img-auto-...` o `tr-img-auto-...`. Los prompts anteriores incluyen `TTITTULARES_IMAGE_JOB_V4` o `TTENDENCIAS_IMAGE_JOB_V4`, además de título/nombre y ID.
- Unir con `ttittulares/image-runs/jobs/*` en rama `control/ttittulares-run-trigger-v2` y `trends/image-runs/jobs/*` en rama `control/ttendencias-run-trigger`, más `ttittulares/prepared.json`, `telegram/editorial-processing.json` y `trends/site-top30-current.json` desde main. **Los índices de jobs pueden contener solo el último registro**: usarlos como pistas, no como cobertura exhaustiva.
- Verificar `project + commandId + editorialId + revision` y, cuando se conserve, `episodeFingerprint`. Si no hay vínculo demostrable, mostrar miniatura `SIN_ASOCIAR` con candidatos y permitir al editor confirmarlo.
- Duplicados de captura mismo SHA+identidad: aceptar reintentos idempotentes sin hacer desaparecer el original. Si hay otro SHA distinto elegido para una misma ficha, mostrar último confirmado como principal y conservar revisiones e historial. No reemplazar fichas de otros commandIds ni revisiones.

### Acceso a ChatGPT Imágenes

Dado que no hay API pública documentada, **la primera implementación es una automatización de interfaz autenticada**, por ejemplo ChatGPT Work / navegador cloud autorizado por el editor. El automatizador debe:
1. Acceder a `https://chatgpt.com/images` usando una sesión legítima y con permiso.
2. Enumerar imágenes accesibles desde interfaz (paginación/scroll real), inicialmente **desde 2026-11-10**.
3. Para cada imagen, abrir su conversación origen si está disponible, identificar `commandId` en el prompt original, y leer/capturar el PNG real mediante controles de la interfaz permitidos; ninguna imagen estimada ni screenshot de baja fidelidad se marcará original.
4. Transferir bytes por HTTPS al endpoint autenticado TT Fotos Site; verificar SHA-256 y recibo.
5. Asociar automáticamente solo si identidad editorial exacta. Si no, guardar en bandeja **TT Fotos sin asociar**. Reportar cada hueco y motivo.
6. Releer la ficha en Site y mostrar la imagen final; no dar éxito solo por tener un prompt o hacer clic.

**La automatización completa de la interfaz no está probada aún**: validar con un piloto (una noticia y una tendencia) antes de recorrer cientos de imágenes. Si la UI impide exportación directa o accesos automatizados, informar el bloqueo concreto. No recurrir a endpoints privados no documentados ni exportar cookies.

## Seguridad y pruebas de aceptación

- Autenticación/editor: rechazar sin OAuth; evitar CORS `*`, CSRF, almacenamiento público, secretos en cliente y subida de archivos arbitrarios. Rechazar no-PNG, >8 MiB y hashes falsos. Analizar autenticación real del Site.
- No contener en respuestas API ni HTML tokens, cookies, bearer iPhone ni ingest key.
- **Aislamiento del iPhone**: cero `POST` a `/api/image-inbox/v1/images/ingest` y `/decision`; comparar conteo/estado APP antes/después de piloto para comprobar ausencia de cambios.
- Dos pruebas físicas: 1 noticia y 1 tendencia de 10 o 11/11/2026 con PNG original. Verificar en monitor remoto miniatura, commandId, revisión, SHA, URL conversación y bytes privados durables.
- Un PNG ambiguo entra a `needs_review`, nunca se asocia por mera similitud visual o fecha.
- Después ejecutar lote limitado por día, registrar `total de Images visto`, `asociadas`, `huérfanas`, `fallidas` y `no visibles`. El total de encargos no debe confundirse con imágenes realmente generadas.
- **No prometer 100 %** si algunas imágenes no aparecen/están borradas/inaccesibles; que cada caso aparezca como estado verificable.

## Estado y siguiente acción

A fecha 11/11/2026, **no implementado ni desplegado** el acceso automático ChatGPT Imágenes -> TT Fotos Site. Lo que existe es un monitor Windows V3 y prototipos en GitHub. Esta especificación reemplaza las sugerencias de continuar con la importación de `C:\\TTiTTulares\\TTFotos-Importar`.

**Siguiente ejecución en ChatGPT Work o entorno con navegador autenticado y permisos de Site:** abrir ambas webs; verificar acceso autorizado a Imágenes, encontrar un PNG de una noticia y uno de una tendencia con ID exacto; inspeccionar backend del Site para crear API **independiente**, construir galería privada y completar un piloto E2E antes de iniciar rescate histórico masivo. Trabajar sin intervenciones sobre la bandeja del iPhone.
