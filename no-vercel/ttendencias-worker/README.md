# TTendencias sin Vercel — alternativa Cloudflare con la app ORIGINAL

**Estado a 8 octubre 2026:** Worker real desplegado en `ttendencias-no-vercel-test.fabricelop.workers.dev`. Panel, API de estado y autenticación comprobados; cuatro imágenes IA completadas y subidas mediante el PC. Código versionado en main por separado de los cambios Windows del PR #105. No modificar FabCalendar, SeLoRecordamos, TTiTTulares ni RainETA.

## Arquitectura funcional

- **Cloudflare Worker independiente**: sirve los 13 archivos originales de `vercel-webhook/ttendencias` en `/ttendencias/` (incluidas Explicadas, PWA y service worker), y `/api/ttendencias-control`, `/api/ttendencias-run`, `/api/ttendencias-run-status`.
- **Reutiliza los tres handlers originales de TTendencias**: el script `scripts/stage.mjs` los copia desde el mismo repositorio y solo sustituye las dependencias nativas de Node que no funcionan en Workers (`sharp` y `web-push`).
- **GitHub**: estado autoritativo `main`, ramas de control, lecturas y escrituras.
- **Windows local**: chat editorial e ImageGen, ACK, puente de raster. Los cuatro scripts usados por TTendencias admiten `TTENDENCIAS_SERVICE_BASE`, sin redirigir TTiTTulares.
- **Fuera de Vercel**: ningún handler de TTendencias necesita llamar a Vercel una vez que la URL se cambie.

## Restricciones importantes antes de activar

1. **Desplegado y validado parcialmente**: rutas HTTP 200, Top 10/próximas en Cloudflare, token móvil y cuatro trabajos IA DONE con raster recibido. Quedan por comprobar operaciones editoriales concretas y umbrales de CPU Cloudflare Free; no se ha probado PC apagado y recuperación.
2. Cloudflare Workers Free limita la CPU a **10 ms por solicitud**, las peticiones a 100.000/día y las subpeticiones a 50 por solicitud (https://developers.cloudflare.com/workers/platform/limits/). Algunas operaciones del handler original pueden superar los 10 ms; **hay que medir en la instancia real antes de concluir que puede funcionar gratuitamente**. No activar automáticamente un plan de pago.
3. Imágenes: el adaptador `src/compat/sharp.js` verifica cabeceras y dimensiones PNG/JPEG/WEBP sin transcodificación. La página original de **Explicadas** se empaqueta con copia al portapapeles convertida a PNG por canvas en el iPhone. Comprobar visualmente y probar raster con imagen real antes de permitir producción. El parser de cabeceras no valida tanto como un decodificador completo.
4. Los avisos Web Push antiguos del panel ya están retirados por los handlers originales, por eso `web-push` no se implementa. Telegram usa GitHub Actions y bot; su webhook compartido con otros proyectos **no se migra en este PR**.
5. El listener Windows ya se actualizó por PR #105 para usar Cloudflare y se observaron cuatro imágenes IA completadas. Chrome/CDP pueden fallar intermitentemente; supervisar ACK y finalización.
6. El backend original usa un secreto `GITHUB_TOKEN` para GitHub Contents y comentarios. Es imprescindible guardarlo **solo** como secreto cifrado del Worker, nunca en código, variables de frontend ni mensajes de ChatGPT. Tiene que disponer de permisos de lectura/escritura sobre el repositorio y sus issues/contents según operaciones.
7. Al cambiar de origen, el token de acceso del panel que está en el almacenamiento local del origen Vercel **no se transfiere automáticamente**; habrá que reintroducirlo en la nueva dirección desde el móvil.

## Comprobar localmente, sin desplegar nada

En una copia local de la rama `feature/no-vercel-phase1-ttendencias-fallback`, desde `no-vercel/ttendencias-worker`:

```sh
npm install --no-audit --no-fund
npm test
npx wrangler deploy --dry-run
npm run dev
```

Comprobar `http://127.0.0.1:8787/health`, `/ttendencias/`, `/ttendencias/explicadas/` y `/api/ttendencias-control?view=state`. El endpoint de estados puede fallar sin `GITHUB_TOKEN` configurado en una instancia que necesita acceso a la API de GitHub; no interpretar fallos como cola vacía. La suite automatizada (incluido un smoke test real de Wrangler sin secretos) corre en `.github/workflows/ttendencias-cloudflare-test.yml`.

## Preparación del despliegue aislado (solo cuando CI y smoke hayan pasado)

Hay que autenticar una sesión de Wrangler en la cuenta Cloudflare del usuario y utilizar el Worker **independiente** `ttendencias-no-vercel-test`. Esto NO afecta a FabCalendar. No ejecutar despliegue directamente desde `main` mientras falte validación.

```powershell
cd C:\ruta\al\repositorio\no-vercel\ttendencias-worker
npm install
npm test
npx wrangler login
npx wrangler deploy
# Guardar manualmente y de forma interactiva los secretos dentro del Worker:
npx wrangler secret put GITHUB_TOKEN
# Opcional, para cambiar el token de acceso del panel:
npx wrangler secret put TTENDENCIAS_CONTROL_TOKEN
```

No pegar el valor de secretos en chats ni logs. No usar `wrangler secret put` contra el Worker de FabCalendar. El despliegue puede fallar por CPU; no dar por válida la migración solo por obtener HTTP 200 en `/health`.

## Paso final de conmutación, después de probar la URL del Worker

1. Verificar lecturas, Top 10, Próximas, Explicadas, acciones de preparar, descartar, reexplicar, valoración y copiado, inicio y ACK editorial desde el PC, y un flujo completo de GAG IA hasta `DONE` y archivo materializado.
2. Solo después, hacer merge controlado y distribuir los scripts locales desde `main`. En Windows, establecer la variable de usuario `TTENDENCIAS_SERVICE_BASE` con la URL HTTPS real del nuevo Worker, **sin mostrar ni insertar credenciales en esa variable**.
3. Reiniciar únicamente los listeners y puente de **TTendencias**, no TTiTTulares/SeLoRecordamos. La variable es de usuario y los procesos antiguos no la incorporan hasta reiniciar. Cambiar el atajo del iPhone y guardar el token del panel en su nuevo origen.
4. Verificar lectura y ejecución con PC apagado (la orden debe quedar en cola), y posteriormente con PC encendido (ACK y procesamiento); confirmar copia de imagen y persistencia.
5. Mantener un rollback claro y evitar apagar a ciegas proyectos en Vercel. La cuota Vercel actual está agotada hasta que el proveedor reactive el equipo o venza el ciclo.

## Pendientes antes de dar la migración por completada

- Validación en Cloudflare real y cálculo de CPU por endpoint.
- Revisión de compatibilidad del `image-proxy` y seguridad del raster, no solo del formato básico.
- Supervisión de fallos intermitentes de Chrome CDP 9223 y ACK durante generación IA.
- Verificación de todos los atajos móviles que todavía usen `europapress-rss.vercel.app`.
- Comprobación de botones y estados editoriales de extremo a extremo; los callbacks Telegram TTendencias se atienden con `trends/telegram_bot.py package-listen` mediante GitHub Actions.

**No tocar FabCalendar:** su backend Cloudflare y la disponibilidad con el PC apagado son requisitos independientes.
