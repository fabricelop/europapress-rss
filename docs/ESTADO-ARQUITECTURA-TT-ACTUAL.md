# TT Actualidad — estado REAL de los proyectos

**Fotografía verificada:** 11 de octubre de 2026, 22:52 (Europe/Madrid).  
**Repositorios principales:** `fabricelop/europapress-rss` y `fabricelop/tt-control`.  
**Objetivo:** no confundir la app oficial con antiguas PWA en Cloudflare, ni confundir código heredado de Vercel con infraestructura operativa.

## Estado de alojamiento y flujo (capa por capa)

| Función | TTiTTulares | TTendencias | SeLoRecordamos |
| --- | --- | --- | --- |
| **Interfaz móvil actual** | **TT Actualidad, GitHub Pages**, compartida con TTendencias | **La misma TT Actualidad en GitHub Pages** | No integrada en esta app |
| Datos editoriales y archivos de estado | **GitHub**, `europapress-rss` | **GitHub**, `europapress-rss` | **GitHub + PC Windows** |
| **Recepción Telegram y botones** | **GitHub Actions nativo** desde 11/10/2026 (ya NO webhook Cloudflare) | **GitHub Actions nativo** (`trends/telegram_bot.py package-listen`) | **PC Windows local** (`selorecordamos/telegram_local.js poll`) |
| Envíos Telegram | Telegram Bot API desde **GitHub Actions** | Telegram Bot API desde **GitHub Actions** | **PC Windows local** |
| `/run` editorial | Telegram → GitHub Actions → trigger GitHub → listener Windows → ChatGPT | Telegram → GitHub Actions → trigger GitHub → listener Windows → ChatGPT | Telegram → listener Windows → tarea local |
| Redacción editorial | **ChatGPT + Windows**, GitHub Actions para guardar resultados | **ChatGPT + Windows**, GitHub Actions para guardar resultados | **ChatGPT/Windows** y GitHub Actions |
| Conversación contextual en Telegram | **Cloudflare Workers AI + D1 como servicio interno temporal**. La entrada Telegram ya está en GitHub Actions, que transmite preguntas por API autenticada. | Bot propio en GitHub Actions; NO confundir con el chat de TTiTTulares. | Bot local; NO es el mismo chat |
| **API de jobs, imágenes, estado y ACK consultadas por PC** | **Todavía Cloudflare**, por defecto `tt-control.fabricelop.workers.dev` (reenviando al Worker `ttittulares-no-vercel-test`) | **Todavía Cloudflare**, por defecto `tt-control.fabricelop.workers.dev` (reenviando al Worker `ttendencias-no-vercel-test`) | No se ha identificado Cloudflare en el circuito principal |
| PWA/paneles web separados y antiguos | Pueden seguir desplegados en Cloudflare como legado; **NO son la app oficial actual** | Igual | No aplica |
| **Vercel** | **NO interviene en el flujo operativo actual descrito** | **NO interviene en el flujo operativo actual descrito** | **NO interviene en el circuito principal verificado** |

## App oficial: TT Actualidad, NO Cloudflare

- **URL oficial:** https://fabricelop.github.io/europapress-rss/
- **Repositorio y fuente:** `docs/index.html` y `docs/manifest.webmanifest` de `fabricelop/europapress-rss`.
- **Alojamiento:** **GitHub Pages**.
- **Una sola app/PWA** con dos pestañas: **TTiTTulares** y **TTendencias**.
- **Lecturas:** archivos JSON públicos de GitHub (`raw.githubusercontent.com`), con copia estática/cache de respaldo.
- **Acciones privadas:** enlaces a Telegram; recepción por los bots, procesadas en GitHub Actions y Windows según función.
- **No proponer migrar estos paneles desde Cloudflare:** ya se migraron; los Worker antiguos son una capa distinta.

## Bot TTiTTulares: migrado el transporte Telegram a GitHub Actions

- **Configuración autoritativa**: `telegram/ttittulares-transport.json` con `mode: native`, `native_ready: true`, `native_commands_ready: true` y `native_chat_ready: true`.
- **Receptor:** `telegram/ttittulares_native_receiver.py`.
- **Workflow:** `.github/workflows/ttittulares-native-telegram.yml`.
- **Watchdog:** `.github/workflows/ttittulares-native-listener-watchdog.yml`.
- El **11/10/2026** el workflow de conmutación **38173268750** verificó el relay Q&A autenticado, eliminó el webhook Cloudflare con `drop_pending_updates:false` y arrancó `getUpdates` desde GitHub Actions. El watchdog verificó después `getWebhookInfo.url` **vacío**, con el listener nativo activo.
- Telegram nativo maneja `/run`, botones (publicar, desestimar, borrar), propuestas de noticias y `/start ttm_...` de TT Actualidad. **No equivale a garantizar instantaneidad:** el receptor registra en GitHub y un workflow posterior aplica la decisión y elimina mensajes.
- **Conversación**: las preguntas se envían por HTTPS a `tt-control.fabricelop.workers.dev/api/telegram-native-question` (autenticación privada) para responder mediante Workers AI/D1. La API de pregunta existe y el preflight real comprobó 403 sin token y 422 para una petición autenticada vacía. **Queda dependencia Cloudflare para la IA conversacional, aunque NO para la recepción Telegram**.
- Las rutas de reparación del webhook antiguo fueron protegidas para no restaurarlo por accidente.

### Incidencia real de borrado tras la conmutación: Betis

- Noticia `c423c8b92c7a` («El Betis de Isco y de Morante golea a Osasuna y es tercero»).
- Dos pulsaciones recibidas en `telegram/ttittulares-callback-inbox.json`: update_ids `218638353` y `218638354`. El bot confirmó enseguida «Decisión registrada en GitHub», **antes de aplicar el borrado**.
- El workflow `process-ttittulares-telegram-decisions.yml` aplicó la decisión más tarde. Verificado **`status=deleted`** en `ttittulares/decisions.json` y `telegram/ttittulares-deliveries.json` a las 20:51:01 UTC.
- Verificado **`status=deleted`** de los mensajes Telegram **3488 (noticia) y 3493 (foto de archivo)** en `telegram/delete-message-queue.json` a las 20:51:12 UTC. El usuario confirmó «Ahora sí».
- **Lección:** «Decisión registrada en GitHub» = recepción, **no** borrado finalizado; la confirmación real debe darse tras persistir estado y completar la supresión en Telegram.

## Bot TTendencias

- **Recibe botones/comandos por GitHub Actions**, no por webhook Cloudflare. `trends/telegram_bot.py package-listen` corre en `.github/workflows/ttendencias-listener.yml` y tiene watchdog `ttendencias-listener-watchdog.yml`.
- **Botón Reexplicar/Actualizar:** lógica corregida 11/10/2026 en receptor activo y tests. Verificar comportamiento extremo a extremo antes de afirmar que toda reexplicación individual terminó.
- **PC aún depende de Cloudflare para las API de trabajos/ACK/imagen**, pero la PWA oficial NO.
- Código heredado (p. ej. enlaces antiguos a Instagram) no implica que la publicación a Instagram siga operativa: la política editorial actual retiró publicación automática a Instagram y X. Inspeccionar flujo vivo antes de afirmar lo contrario.

## SeLoRecordamos

- Telegram: `selorecordamos/telegram_local.js` en Windows, lanzado desde `selorecordamos/run-telegram-listener.ps1`.
- Edición y `/run` mediante tareas Windows; persistencia GitHub y aplicación editorial con GitHub Actions (incluido issue #16 para outbox).
- **Sin dependencia Cloudflare o Vercel identificada en su circuito principal.**
- No confundir su receptor local con los de TTendencias/TTiTTulares en GitHub Actions.

## ¿Qué API siguen consultando los listeners Windows?

Ambos scripts `windows/TTiTTularesDedicatedListener.ps1` y `windows/TTendenciasDedicatedListener.ps1` usan por defecto `$StatusBase = https://tt-control.fabricelop.workers.dev`. Consultan:

- `/api/ttittulares-run-status?view=listener-snapshot`
- `/api/ttittulares-run-status?view=image-job&strong=1&id=...`
- `/api/ttittulares-run`
- `/api/ttendencias-run-status?view=listener-snapshot`
- `/api/ttendencias-run-status?view=image-job&strong=1&id=...`
- `/api/ttendencias-run`

Esas API coordinan **trabajos, imágenes, estados y ACK**; no alojan TT Actualidad. Apagarlas sin sustitución puede romper procesamiento o confirmaciones, aunque GitHub Pages siga funcionando.

**Incidencia anterior, independiente del borrado Betis**: el `/run` de TTiTTulares `tt-1791749086277-tg-841f8f` fue lanzado desde Windows (log `EDITORIAL PROCESS STARTED`, `CHAT MESSAGE CONFIRMED`, `LAUNCH CONFIRMED`), pero el backend devolvió `ACK CONFLICT 409` y GitHub no reflejó correctamente el ACK. Ese `/run` ocurrió **antes** de la migración del webhook a GitHub Actions.

## Pendiente real para dejar Cloudflare por completo

1. Reemplazar las API de trabajos/estados/imágenes/ACK de ambos listeners Windows, **sin perder jobs ni confirmaciones**.
2. Reemplazar el backend temporal de IA conversacional TTiTTulares (Workers AI + D1), manteniendo preguntas, contexto y borrado de pares de mensajes, **sin costes adicionales**.
3. Verificar cada función real extremo a extremo: `/run` tras conmutación, decisiones, reelaboración, chat contextual, propuesta manual y estados de imagen.
4. Desactivar después los Workers antiguos, sus pasarelas y tareas obsoletas, sin tocar Workers de **otros proyectos**, como FabCalendar.
5. **Mantener TT Actualidad en GitHub Pages. No recrearla ni migrarla otra vez.**

## Actualización operativa 11/10/2026 — borrado inmediato y coherencia de Explicadas

- **TTiTTulares Telegram nativo:** `telegram/ttittulares_native_receiver.py` ahora intenta borrar **directamente** la tarjeta y sus fotografías de archivo asociadas mediante Telegram `deleteMessage` inmediatamente después de validar su vínculo con el evento y registrar la decisión durable en GitHub. La GitHub Action de decisiones continúa como respaldo, reconcilia `Listas` y reintenta si falla Telegram. Evitar afirmar un tiempo garantizado: queda por observar una pulsación real después del cambio.
- **TTendencias Top 30:** `trends/auto_queue_new.py` encola automáticamente **solo los diez primeros puestos**. Las posiciones 11-30 son visibles, pero requieren una orden expresa **«Preparar novedad»** desde TT Actualidad para incorporarse a `trends/editorial-queue.json`. Las pendientes legadas 11-30 encoladas automáticamente se marcan inactivas; no eliminar explicaciones históricas ni enviarlas automáticamente por sorpresa.
- **TT Actualidad (GitHub Pages):** la pestaña Top 30 **no considera «EXPLICADA» una redacción solo por estar guardada en `trends/explained.json` o `trends/telegram-manual-explained.json`**. Para habilitar copiar/publicar, exige entrega final de **esa identidad y revisión** en el ledger `trends/telegram-image-deliveries.json`. Si ya se recibió, la tarjeta se ve en **Explicadas**; al cerrarla puede conservarse el historial en Top.
- **Distribución TTendencias:** `apply-ttendencias-chat-outbox.yml` y `repair-ttendencias-explicadas.yml` despachan el workflow `send-ttendencias-explained-telegram.yml` inmediatamente; no se espera al cron ni a una imagen.
- **Recuperación confirmada:** el 11/10/2026 a las **23:20:32 Madrid** Telegram recibió las cinco explicaciones finales de **Raba, Corberan, Racing, #jotalent5 y Aguirre**, IDs de mensaje 687-691. La segunda pasada registró `delivered=0 updated=0 skipped=5` (sin duplicaciones).
- **No confundir recepción y resultado:** TTiTTulares «Decisión registrada» no garantiza que esté borrada la tarjeta salvo éxito de `deleteMessage`; TTendencias «texto explicado» en GitHub no garantiza entrada a Explicadas sin `final:true` en el ledger de entregas.

## Regla operativa para futuros chats

- Nunca decir que **la app unificada TT Actualidad** está en Cloudflare o Vercel: está en **GitHub Pages**.
- Nunca decir que **el receptor Telegram TTiTTulares** sigue en Cloudflare sin comprobar `ttittulares-transport.json` y `getWebhookInfo`: desde el 11/10 está en **GitHub Actions**.
- Nunca decir que se **eliminó toda Cloudflare**: quedan **API del PC y Q&A de TTiTTulares**.
- No deducir uso de Vercel por `vercel.json`, `vercel-webhook` o READMEs desactualizados.
- No confundir «el bot recibió una orden» con «la acción se aplicó» o «el trabajo editorial terminó».
- Este documento es un **estado fechado**: volver a comprobar GitHub antes de afirmar estado futuro.
