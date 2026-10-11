# Comando `/run` para los tres bots de Telegram (2026-10-11)

## Contrato

- `/run` **solo** actúa en el chat privado autorizado del bot correspondiente.
- **TTendencias**: `trends/telegram_bot.py` y el receptor nativo de callbacks registran una orden en la rama `control/ttendencias-run-trigger`, fichero `trends/run-now-trigger.json`; el listener Windows existente la recoge. Se admite además `/tendencias` como alias.
- **TTiTTulares**: los receptores `api/telegram-webhook.js` y `vercel-webhook/api/telegram-webhook.js` registran una orden en `control/ttittulares-run-trigger-v2`, fichero `ttittulares/run-now-trigger.json`, usando el `GITHUB_TOKEN` existente. Para ejecutar `/run`, exigen autenticación con `TELEGRAM_WEBHOOK_SECRET` además de validar el chat privado. **Importante: esta implementación del repositorio NO demuestra que el webhook productivo `tt-control.fabricelop.workers.dev` haya recibido el cambio. No redirigir ni sustituir el Worker en producción sin examinar su fuente vigente; los botones deben preservarse.**
- **SeLoRecordamos**: `selorecordamos/telegram_local.js` recibe `/run` o `/sr_run`; solicita la tarea `SeLoRecordamos-Editorial-Local` mediante `schtasks` oculto. Responde aunque no haya evaluaciones pendientes. El arranque confirmado no equivale a redacción terminada.
- Las tres rutas tienen confirmación **de solicitud** y prevención de órdenes repetidas; **no** se afirma finalización editorial hasta que haya estado final comprobado.
- No se modifica la planificación automática Windows ni se introduce Ollama ni otra automatización ChatGPT.

## Activación y comprobación

En el PC Windows, una sola vez tras los cambios de GitHub:

```powershell
cd "$env:USERPROFILE\europapress-rss"
git pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { throw "Error actualizando el repositorio" }
Stop-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-ScheduledTask -TaskName "SeLoRecordamos-Telegram"
Get-ScheduledTask -TaskName "SeLoRecordamos-Telegram","SeLoRecordamos-Editorial-Local" |
    Select-Object TaskName, State
```

Enviar `/run` al bot SeLoRecordamos y confirmar la respuesta. Si no responde, revisar `selorecordamos/runtime/telegram-listener.log`, buscar `SR_RUN_RECEIVED` o `SR_RUN_ACK_FAILED`.

Enviar `/run` a @TTendenciasES_bot y comprobar el mensaje con ID `tr-...`, después verificar la rama de control y la pasada editorial.

**No considerar TTiTTulares validado en producción** hasta integrar su código en el Worker Cloudflare realmente desplegado y recibir un ACK `tt-...` en @TTiTTulares_bot.

## Verificación automatizada

`.github/workflows/ttendencias-telegram-native-callback-poller.yml` compila/valida los receptores y ejecuta pruebas offline para los contratos de GitHub, Telegram, idempotencia y autorización. No envían órdenes a bots reales.
