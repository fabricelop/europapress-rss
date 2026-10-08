# TTiTTulares — migración a Cloudflare sin Vercel (STAGING)

Estado: **solo rama/PR de pruebas**. No interrumpir producción ni cambiar el webhook de Telegram hasta las validaciones manuales.

## Arquitectura
- Worker separado `ttittulares-no-vercel-test`, sin conexiones con los Workers de TTendencias, TT Control o FabCalendar.
- Reutiliza el panel PWA ORIGINAL `vercel-webhook/ttittulares` (sin rediseñarlo), y los handlers originales `ttittulares-control-handler.js`, `ttittulares-run-handler.js`, `ttittulares-run-status-handler.js` y las valoraciones.
- Rutas: `/ttittulares/`, `/api/ttittulares-control`, `/api/ttittulares-run`, `/api/ttittulares-run-status` y `/health`. El widget se consulta como `/api/ttittulares-control?view=widget`.
- El adaptador `sharp` comprueba dimensiones PNG/JPEG/WEBP; **no modifica píxeles**. La PWA ya convierte imágenes a PNG mediante Canvas en el navegador.
- La generación de IA seguirá con el PC, Chrome, ImageGen y su puente, pero NO tocar scripts Windows hasta validar el Worker en una URL real.
- Estado y colas siguen almacenados en el repositorio GitHub existente. El flujo radar/editorial/Telegram sigue desde GitHub Actions y el PC; no hay nueva base de datos ni migración de colas.
- **Webhook de Telegram**: el bot de TTiTTulares usa un webhook independiente alojado en `tt-control.fabricelop.workers.dev`. No se migra ni modifica en esta fase; se comprobará por separado para los botones Publicado/Desestimar.

## Seguridad
- `GITHUB_TOKEN` fine-grained solo para `fabricelop/europapress-rss`, permisos Contents read/write y Issues read para lectura del PR editorial.
- `TTITTULARES_CONTROL_TOKEN` token independiente, secreto de Cloudflare y guardado en Ajustes del navegador.
- **No** copiar credenciales a código fuente ni reutilizar el secreto/Worker de FabCalendar o TTendencias.
- El preview no omite autenticación: `VERCEL_ENV=production` forzado en el Worker.

## Pruebas CI
1. `npm install --no-audit --no-fund`, `npm test`, `npx wrangler deploy --dry-run`.
2. Smoke local `wrangler dev`: health, PWA, rechazo sin token y lectura pública del estado.
3. ZIP ligero `ttittulares-cloudflare-light` publicado como artifact, sin copiar todo el repositorio.
4. Solo después, deploy separado desde Windows e introducir los secretos mediante Wrangler `secret bulk` sin prompts.
5. Probar desde el móvil: API GET completa, Ajustes, ping autenticado, preparar una noticia, cancelación/revisión, cola editorial, imagen real hasta DONE, Telegram y botones terminales.

## Limitaciones y no-go
- **Cloudflare Workers Free**: 10 ms CPU por request y un número finito de subpeticiones; algunas respuestas con JSON GitHub grande podrían fallar. No migrar producción hasta probar con estado real y sin pagar nada.
- Los handlers siguen utilizando GitHub y pueden alcanzar su cuota, independientemente de Cloudflare.
- 1 trabajo de imagen simultáneo recomendado por PC; no arrancar otro listener que compita con el actual.
- Desconocemos hasta dónde los antiguos botones Telegram fallan por el webhook compartido: **esto no queda resuelto por un HTTP 200 del nuevo panel**.
- No modificar Vercel/TTiTTulares producción, tt-control, TTendencias, SeLoRecordamos, FabCalendar, RainETA ni Money Control sin pruebas y permiso.
