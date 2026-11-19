# Noticias V2 — reloj Cloudflare de respaldo

Este Worker es **nuevo y aislado**. No sirve páginas, no abre Chrome, no escribe
directamente en GitHub, no publica noticias y no modifica el Worker de Tendencias.
Ejecuta un cron de Cloudflare cada diez minutos (minutos 05,15,25,35,45,55 UTC).

## Qué hace

1. Lee `state/radar/live-summary.json` de la rama independiente
   `ttactualidad-v2-radar-live` (sin autenticación; repositorio público).
2. Si `observed_at` tiene menos de 20 minutos, termina sin efectos.
3. Si está desactualizado, consulta las cinco ejecuciones más recientes del
   workflow `ttittulares-v2-radar-clock.yml` en `main`.
4. Si ya hay una ejecución reciente o activa, no envía otra solicitud.
5. En caso contrario, solicita a GitHub `workflow_dispatch(ref=main)` y exige
   HTTP 204. **GitHub**, no Cloudflare, sigue haciendo el barrido y guardando
   los jobs de Noticias V2 mediante sus mismas transacciones CAS.

El Worker registra códigos y antigüedad sin imprimir tokens ni datos de
sesiones. Un error de lectura/credenciales falla cerrado; no envía a ciegas.

## Activación controlada

1. En GitHub, crear un **fine-grained PAT** para **solo** el repositorio
   `fabricelop/europapress-rss`, con permiso **Actions: write** y caducidad
   elegida. No enviarlo por chat. Crear el secreto del repositorio Actions
   `TTN2_RADAR_DISPATCH_TOKEN` con ese valor.
2. Confirmar que el repositorio ya tiene los secretos de despliegue
   `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`, con permisos sobre el
   Worker nuevo. Si faltan, el workflow fallará **antes del despliegue**.
3. Fusionar la PR en `main`. El workflow
   `.github/workflows/ttn2-radar-clock-cloudflare-deploy.yml` ejecutará las
   pruebas, desplegará **solo** `ttactualidad-v2-noticias-radar-clock`, pondrá
   el token en el secreto Cloudflare `GITHUB_DISPATCH_TOKEN` y comprobará
   presencia del secreto y expresión cron en la API real de Cloudflare.
4. Esperar la propagación del Cron Trigger; comprobar una ejecución externa
   con `TTN2_RADAR_CLOCK_DISPATCH_ACCEPTED` en los logs, un nuevo workflow
   GitHub `workflow_dispatch` y finalmente `observed_at` más reciente en la
   rama de radar. La presencia del cron no prueba por sí sola que funcione.

El schedule histórico de GitHub se mantiene como disparador redundante. Las
peticiones repetidas del reloj no abren chats ni saltan la protección de
revisión y concurrencia del radar. El token tiene caducidad: debe renovarse
antes de expirar para mantener el respaldo automático.

## Validación sin secretos

```bash
node --check src/index.mjs
node --test tests/radar-clock.test.mjs
```

Esta integración **no corrige** los problemas de captura/editorial en el PC.
No reinstalar consumidores ni reintentar respuestas inciertas al activarla.
