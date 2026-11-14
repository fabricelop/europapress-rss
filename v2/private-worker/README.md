# TTActualidad V2 — acceso privado a coste cero (candidato)

Este proyecto monta una COPIA de la PWA real `docs/v2/` de `main` en un Cloudflare Worker **independiente**. No modifica ni FabCalendar, ni V1 ni la web pública hasta un corte controlado.

## Seguridad
- Sin secretos en GitHub ni navegador: `AUTH_PASSWORD` (al menos 16 caracteres) y `SESSION_SECRET` (32 o más caracteres aleatorios) son **Cloudflare Worker Secrets**.
- Cookies firmadas HMAC, HttpOnly + Secure + SameSite=Strict, expiran en 30 días. Cerrar sesión invalida la cookie de ese navegador; rotar `SESSION_SECRET` invalida todas.
- `assets.run_worker_first=true`: cada acceso a HTML, JS, CSS, iconos y API se autentica; las peticiones sin cookie no reciben archivos.
- El código no usa KV, D1 ni R2 para login; no necesita cron ni añade consumo de almacenamiento. Se carga la página y se consulta el Top30 mediante un proxy autenticado.\n- Login: binding Cloudflare Rate Limiting `LOGIN_LIMITER`, aprox. 5 intentos por minuto y dirección de red dentro de cada ubicación (no es un bloqueo global estricto). No requiere escrituras KV.
- Las acciones editoriales están bloqueadas deliberadamente hasta habilitar un endpoint seguro y comprobar el flujo E.
- **Limitación temporal de privacidad:** el snapshot de Top30 original aún existe en el repositorio GitHub público, y la página anterior de GitHub Pages sigue pública. Esta primera fase protege la COPIA de Cloudflare, NO hace confidencial el origen. Para privacidad integral, trasladar también los datos a almacenamiento privado y retirar el sitio público.

## Preparación (NO desplegado)
1. Instalar Node 22 y ejecutar `cd v2/private-worker && npm install && npm run check`.
2. Iniciar sesión con Wrangler en una cuenta Cloudflare **Free**.
3. Crear un Worker NUEVO `ttactualidad-v2-private-test`; no modificar Workers de FabCalendar/TT.
4. Definir secretos sin copiarlos a GitHub ni a ChatGPT: `npx wrangler secret put AUTH_PASSWORD` y `npx wrangler secret put SESSION_SECRET`. Para una contraseña larga, usar gestor de contraseñas.
5. `npm run build && npx wrangler deploy`. El nombre de prueba es distinto del resto de Workers.
6. Verificar por URL pública: `/health` devuelve estado; `/` presenta login; `/app.js` sin cookie devuelve 401; con cookie se ve Top30; `/api/state/web-top30.json` solo responde con sesión; `/api/accion-inexistente` nunca modifica cola.
7. Confirmar costes/cupos en Cloudflare antes del corte. Se mantiene GitHub Pages hasta superar las pruebas.

## Cuotas
El Worker Free tiene 100.000 invocaciones/día en el conjunto de la cuenta y 10 ms CPU por petición. Como se exige autenticación previa para **cada archivo**, estos accesos cuentan; el objetivo es mantenerlo bajo unas pocas centenas/día para un editor. El upstream GitHub se cachea 30 s; no hay escrituras KV de sesión.

## Próximas fases
- Entregar la imagen de Jordi Wild desde un recurso privado, no el URL GitHub directo.
- Reemplazar el botón R de marca roja por botón separado E; E enviará revisión autenticada y hará CAS sobre el estado, sin sobrescribir chats activos.
- Sustituir repositorio público como origen del Top 30 y retirar la web pública, sin afectar V1.
- Mantener una contraseña larga, única y aleatoria; el limitador de Cloudflare no sustituye la fortaleza de la clave.

No activar pagos ni vincular despliegue automático sin autorización explícita.

## Duración de sesión
Se ha preparado `SESSION_HOURS=720` (30 días exactos). El código valida el máximo de 30 días para la firma; tras desplegar la nueva versión la cookie existente de 12 horas sigue expirando en su fecha anterior y el próximo inicio de sesión emitirá una cookie de 30 días. No hay renovación silenciosa, cada navegador tiene su propia cookie. Reiniciar sesión o borrar cookies requiere entrar otra vez.


## Imágenes ImageGen V2 (arquitectura equivalente a V1)

**La miniatura de Jordi Wild no es el procedimiento definitivo.** V1 recupera el original renderizado del ChatGPT concreto, comprueba la relación inmutable con el trabajo editorial (ID, revisión, comando, hash del texto), guarda el fichero real en `generated-images` y asocia su URL a la entidad editorial.

V2 mantiene el mismo contrato de identidad pero almacena imágenes **privadas** en R2, no en carpetas públicas de GitHub:
1. Tras capturar la explicación, programar un trabajo ImageGen **por tendencia/revisión**, con `command_id` exclusivo y `editorial_sha256` del texto exacto capturado.
2. Generar mediante ImageGen en la conversación correspondiente. El receptor de V2 debe recuperar el **raster original** de la respuesta, sin hacer capturas de pantalla, miniaturas ni regeneraciones involuntarias.
3. Subirlo al Worker usando `POST /api/image-ingest` con secreto de ingestión **solo en Windows**, nunca en el navegador ni en GitHub. Cabeceras: `x-ttv2-image-ingest`, `x-ttv2-trend-id`, `x-ttv2-revision`, `x-ttv2-command-id`, `x-ttv2-editorial-sha256`, `x-ttv2-raster-sha256`, `x-ttv2-width`, `x-ttv2-height`, `content-type`. Cuerpo: fichero original PNG/JPEG/WebP, máximo 8 MiB y mínimo 100 KB.
4. El Worker verifica la tendencia y revisión **actualmente presentes en el Top 30**, hash editorial, tipo binario y SHA256 de píxeles/carga, y rechaza duplicidades o imágenes de otra revisión. Conserva el original en el bucket `ttactualidad-v2-images`, con referencia en `v2_images` de D1.
5. La aplicación muestra cada imagen exclusivamente mediante `GET /api/image/<trend_id>?revision=N` **con sesión**. Si no existe todavía, no muestra una miniatura falsa.
6. Si la explicación pasa a otra revisión, su imagen anterior permanece archivada en R2, pero no aparece en la revisión nueva. No se usan imágenes de otros elementos por semejanza de nombres.

**Estado de implementación:** backend privado y presentación genérica preparados en rama; el receptor Windows ImageGen V2 y su registro automático de trabajos todavía deben conectarse. La creación del bucket R2, la clave `IMAGE_INGEST_SECRET` y el despliegue de esa versión también están pendientes. **No desplegar** hasta tener el bucket y D1. No solicitar al usuario descargas manuales por cada imagen.

Nota de cuotas: R2 Standard Free contempla almacenamiento y operaciones gratuitos dentro de determinados límites; puede requerir habilitación en la cuenta y cualquier exceso puede facturarse según las condiciones de Cloudflare. Verificar antes de activar.
