# Centro de Reparaciones · Proyectos APP · v1.0

Panel PWA **bajo demanda**, Cloudflare Worker + Google OAuth + GitHub Actions + cola persistente Cloudflare D1 + agente Windows. Este paquete contiene código y pruebas. No está desplegado ni enlazado a tu cuenta Google hasta completar la instalación; las reparaciones de producción no se han ejecutado mediante este paquete.

## Alcance verificable

- **Sin PC:** la interfaz y las solicitudes GitHub Actions funcionan desde Safari o Windows si Cloudflare y GitHub están configurados. Soporta `TTiTTulares radar`, `TTiTTulares Listas/imágenes (encolado)`, `TTendencias radar`, `TTendencias Explicadas/imágenes (encolado)`, `TTActualidad pruebas`, `SeLoRecordamos verificación y pruebas de Telegram`, `RainETA radar/pruebas`. Cada operación llama al workflow ya existente sin cambiar sus archivos.
- **Diagnósticos de colas:** lee estado versionado de TTiTTulares, TTendencias y SeLoRecordamos, y diferencia `OK`, `incidencia` y `sin datos`. La indicación OK se refiere únicamente al chequeo implementado, no a todo el servicio.
- **Con PC:** órdenes locales persistidas en D1; el agente consulta solo órdenes manuales. Sin tareas locales autorizadas, *no repara* ni ejecuta scripts. Los botones locales quedan en `needs_configuration`. Nunca relanza una orden perdida con resultado incierto.
- **Integración parcial:** FabCalendar, AquíEstuve, PokerPilot, LotoLab, widget de lluvia y ejecución editorial directa figuran en el menú, pero requieren integración particular para permitir reparaciones. No se inventan endpoints ni se finge reparación.
- **TT Telegram antiguo:** marcado desactivado porque los workflows actuales son tareas vacías; no reactivarlo automáticamente.
- **Sin monitorización, alertas, cron ni tareas periódicas de diagnóstico.** El agente Windows únicamente comprueba si *ya hay una orden solicitada*, sin auditar otros proyectos espontáneamente.

## Configuración una sola vez

### A) Google OAuth (requiere acción del propietario)

En [Google Cloud Console](https://console.cloud.google.com/apis/credentials) configura un **OAuth 2.0 Client ID, tipo Aplicación web** y una pantalla de consentimiento con tu cuenta como usuario de prueba, si la aplicación está en modo Testing. Añade como **Authorized redirect URI** la URL exacta de Cloudflare: `https://centro-reparaciones.TU_SUBDOMINIO.workers.dev/api/auth/callback` (sustituye TU_SUBDOMINIO). Conserva el Client ID y Client Secret. Solo se acepta el correo indicado en `ALLOWED_EMAIL`. Las claves Google se verifican criptográficamente con JWKS y se comprueban firma, audiencia, caducidad y dirección verificada.

### B) GitHub (requiere acción del propietario)

Usa un **fine-grained personal access token** limitado al repositorio `fabricelop/europapress-rss`, con permisos `Actions: Read and write` y `Contents: Read`. No incluyas token en archivos, Git ni interfaz. El Worker necesita leer los archivos de estado y solicitar `workflow_dispatch` del despachador. GitHub Actions utiliza su `GITHUB_TOKEN` interno para abrir workflows permitidos.

En el repositorio `fabricelop/europapress-rss`, copia **toda esta carpeta** a la ruta `repair-center/` y copia adicionalmente `repair-center/.github/workflows/repair-center.yml` a `.github/workflows/repair-center.yml`. Puedes hacer un PR primero y pasar a main tras revisión. **El workflow debe existir en main** antes de solicitar reparaciones remotas. `repair-center/dispatch.py` valida cada nombre con una lista blanca.

### C) Cloudflare (sin Vercel)

Crea un Worker **nuevo**, sin sustituir los Workers de TTActualidad/TTendencias existentes.

Desde la carpeta de este paquete en Windows con Node.js y una sesión Cloudflare autorizada:

```powershell
npx wrangler login
npx wrangler d1 create centro-reparaciones
Copy-Item wrangler.example.toml wrangler.toml
# Editar wrangler.toml: GOOGLE_CLIENT_ID, ALLOWED_EMAIL y el database_id recibido
npx wrangler d1 execute centro-reparaciones --remote --file schema.sql
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put COOKIE_SECRET
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put AGENT_KEY
npx wrangler deploy
```

Genera `COOKIE_SECRET` y `AGENT_KEY` con 32+ bytes aleatorios independientes: por ejemplo, `python -c "import secrets; print(secrets.token_urlsafe(48))"`, dos veces. Conserva la clave del agente para su instalación. **No ejecutes el deploy hasta tener OAuth configurado y las credenciales listas.** Cloudflare ofrece planes gratuitos sujetos a cuotas; comprueba tu cuenta antes de configurar.

### D) Agente Windows (opcional, una sola vez)

Una vez publicado el Worker, en la carpeta `windows/`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Agent.ps1
```

Edita `%LOCALAPPDATA%\CentroReparaciones\agent-config.json` con la URL HTTPS y los nombres **exactos** de las tareas verificadas en tu PC. **`allow_start=false` por defecto**: diagnostica sin iniciar procesos. Solo cambia a `true` si estás seguro de que esa tarea es idempotente y su relanzamiento no duplica trabajos. La clave se almacena cifrada con DPAPI para el usuario Windows actual, no en texto plano. La tarea local consulta cada 2 minutos *únicamente la cola de órdenes* (no hace auditorías automáticas).

## Uso cotidiano

1. En iPhone abre el Worker publicado en Safari, autentícate con tu cuenta Google, pulsa **Compartir > Añadir a pantalla de inicio**.
2. Selecciona uno o varios procesos. Pulsa **Diagnosticar ahora** para leer sus estados sin alterar nada. Pulsa **Reparar seleccionados** para solicitar solamente las operaciones con modo `Nube` o `PC`.
3. Consulta **Consultar progreso** bajo demanda. `submitted` significa que GitHub aceptó la orden; `dispatched_unverified` significa que el despachador terminó, *NO que se completó el workflow hijo ni se resolvió el problema*. Vuelve a diagnosticar y revisa el enlace de GitHub Actions si persiste el atasco.
4. Si un agente Windows se desconecta durante una ejecución, tras 15 min la operación se marca **fallida / incierta** al consultar. No se relanza sola y no borra datos.

## Pruebas (sin acceso a producción)

```bash
node --test tests/worker.test.mjs
python -m unittest discover -s tests -p dispatch_test.py -v
node --check worker.mjs
node --check public/app.js
```

Estas pruebas cubren las reglas de acceso, firma Google, OAuth, detección, rechazo de órdenes no autorizadas, dispatch mock, cola local mock e idempotencia básica. **No certifican el inicio/fin real de cada workflow, el Login OAuth real ni la recepción en iPhone**: se requiere desplegar primero y hacer una prueba controlada con credenciales autorizadas.

## Protección del panel

- Autorización basada en correo Google verificado y JWT con firma RS256, sesión firmada HMAC, cookie HttpOnly+Secure, flujo PKCE/state, CSRF y comprobación Same-Origin.
- No se aceptan comandos shell arbitrarios, workflows enviados por el cliente ni nombres de tareas Windows procedentes del servidor. Las tareas están en allowlist local.
- Ningún cambio destructivo, borrado masivo, publicación en redes, regeneración de datos ni cambios de código automáticos.
- Si Cloudflare/GitHub está caído, la interfaz muestra un error y mantiene el trabajo sin proclamar `Reparado`.
- La salud pública `/api/health` solo expone nombre/versión y no credenciales.

### Opción sencilla para incorporar el código al repositorio

Si en Windows tienes `git` y GitHub CLI (`gh auth login`) ya autorizados, ejecuta en la raíz extraída del ZIP:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Repo.ps1
```

Creará una **rama y un Pull Request**, sin tocar `main` ni activar nada por sí solo. Después de revisar/combinar el PR, prepara Google OAuth/Cloudflare siguiendo las instrucciones anteriores. El despliegue Cloudflare no está automatizado porque faltan credenciales que **no deben enviarse al chat**.
