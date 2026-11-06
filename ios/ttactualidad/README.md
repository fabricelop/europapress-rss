# TTActualidad iOS 0.2.0 · SwiftUI + Live Activity + GitHub

Aplicación iPhone nativa, coste **0 €**, instalable desde Windows mediante **PlumeImpactor**. Rediseño oscuro, icono propio de globo y periódico, sin Cloudflare.

## Interfaz

- **TTiTTulares:** Listas, En elaboración, Revisión, Creciendo y Tremending. Tarjetas con título, explicación, fuentes, fecha, remate e imagen de archivo si existe.
- **TTendencias:** Top 30 por defecto, Listas y En elaboración. Filas compactas desplegables, fecha de explicación y colores verde (<12 h), amarillo (12–24 h), rojo (>24 h), neutro sin explicación.
- Contadores de **Listas** de noticias y tendencias. Live Activity con ambos contadores para pantalla bloqueada y Dynamic Island. **Sin widgets** convencionales.
- Buscador, refresco manual, gestos de expansión, caché local y marca de datos parciales.

## Acciones editoriales

- **＋ Noticia:** formulario para titular, enlace HTTPS e instrucciones; se envía a GitHub mediante el evento `ttactualidad_manual_news_v1`.
- **Quitar de Listas, preparar, descartar, reelaborar:** evento `ttactualidad_action_v1` con `event_id` y `revision`; GitHub aplica la acción en su workflow existente.
- **Publicar en X, Buscar en X, TTImages, Abrir ChatGPT Images, Copiar GAG, Copiar texto y Copiar foto de archivo** funcionan desde controles nativos, según el contenido disponible.

**Limitación de seguridad inicial:** las acciones que escriben en GitHub requieren configurar e instalar una **GitHub App** con Device Flow y permiso limitado `Contents: Read/Write` sobre el repositorio. Se introduce una vez el **Client ID público** de la GitHub App en la pantalla «Conexión GitHub», se autoriza la cuenta en GitHub y el token de usuario se guarda en Keychain. No hay tokens secretos incrustados en la IPA ni se pide un PAT. **La recepción HTTP 204 de GitHub confirma la solicitud, no su aplicación final**: la operación editorial sigue su workflow y debe verificarse mediante el estado de GitHub. Sin configurar esa GitHub App, las consultas, copias y enlaces funcionan, pero las acciones de escritura no.

## Live Activity

Se crea al consultar GitHub cuando iOS autoriza Live Activities. Se refresca al abrir o actualizar la aplicación y marca obsoletos los datos tras 30 minutos. **Sin APNs no se garantiza refresco con la app cerrada o suspendida.** La IPA incluye `TTActualidadLive.appex`; PlumeImpactor tiene que firmar la extensión y la aplicación.

## IPA (PlumeImpactor)

1. Abre la ejecución **TTActualidad iOS - PlumeImpactor IPA**: https://github.com/fabricelop/europapress-rss/actions/runs/40406852994
2. En **Artifacts**, descarga `TTActualidad-0.2.0-PlumeImpactor-IPA`.
3. Descomprime el ZIP y abre `TTActualidad-0.2.0-PlumeImpactor-unsigned.ipa` desde PlumeImpactor en Windows, como con MiMapaDelTiempo.
4. Instálala sobre la versión anterior. Comprueba el icono y la Live Activity en el iPhone.

La compilación Xcode se ha verificado en GitHub Actions, incluida la creación del icono de 1024×1024 y el paquete de la Live Activity. La instalación y las autorizaciones de GitHub siguen requiriendo verificación en el dispositivo real.

## Identificadores

- App: `com.fabricelop.ttactualidad.native`
- Live Activity: `com.fabricelop.ttactualidad.native.live`

La instalación no modifica ni sustituye TTActualidad web, MiMapaDelTiempo, FabCalendar ni los procesos de TTImages. GitHub es la fuente editorial; no se ha editado el backend ni las automatizaciones existentes.

## Galería de fotografías de archivo

La sección **Fotos archivo** reúne únicamente las fotografías de archivo actualmente vinculadas a noticias y tendencias. Resuelve archivos guardados en `ttittulares/archive-images/` y `trends/archive-images/` de GitHub por identificador y revisión editorial, y utiliza referencias `archive_image` / `fallback_image` del estado vigente. Un archivo ausente se marca como no disponible; nunca se sustituye por una imagen IA. Permite ampliar, abrir el original y copiar la fotografía desde el iPhone. **No descarga ni indexa imágenes IA** de ChatGPT Images, TTImages ni de `generated-images/`. El acceso a ChatGPT Images continúa mediante su botón independiente.



## TTActualidad iPhone 0.4.64 build76 — publicación directa Buffer Free (propuesta aislada)

**Base técnica:** app moderna de PR #314 (Relaciones) más **PR #325** (Top 30 / noticias nuevas / máximo 20 imágenes pendientes). La PR de Buffer #322 está basada directamente en la rama de #325 y utiliza 0.4.64 build76. **No usar la versión antigua del README/IPA 0.2.0 para esta función.** Esta implementación se mantiene como PR dependiente sin reemplazar las funciones de relaciones, imágenes, edición, histórico, pendientes ni Live Activities.

**Dos acciones completamente independientes:**
- «Publicar en X»: **sin cambios**; abre el compositor X con el texto preparado, conserva la foto manual y las decisiones posteriores.
- «Publicar directo · Buffer»: un toque individual desde una ficha **en Listas**, siempre que tenga texto editorial válido; adjunta imagen IA verificada, en su defecto foto de archivo asignada o, si no hay imagen, publica solo texto; transmite una solicitud editorial autenticada a GitHub. No abre X y asigna rígidamente @ttittulares a noticias y @ttendenciasesp a tendencias. No publica por sí sola al generar o elaborar una noticia.
- En el panel aparecen dos nuevos contadores **DIRECTAS X** independientes de los actuales «24 h publicados»: total confirmado en X por Buffer, confirmados durante 24 h móviles, y operaciones pendientes. Un HTTP 204, post reservado, en cola, fallido o de estado incierto **no aumenta** el contador.
- Cierre de Listas a través del mismo flujo GitHub `ttactualidad_action_v1` solo **después** de confirmación real del estado `sent` del post por Buffer. Los eventos manuales existentes y su histórico no se alteran.

**Credenciales y puesta en marcha (sin coste añadido):** el usuario ya tiene una cuenta Buffer, pero debe conectar dentro de Buffer las **dos cuentas X** y generar su API key. En GitHub, repositorio → Settings → Secrets and variables → Actions, debe guardar la clave como secreto `BUFFER_API_KEY`. Jamás introducirla en la app, en un chat o en un commit. Conexión de X o secreto ausentes → bloqueo seguro, sin envío. La publicación está implementada en `pilot/ttactualidad_buffer_publish.py` y `.github/workflows/ttactualidad-buffer-publish.yml` (solo ejecutables tras fusionar el código a main); lecturas y estado en `pilot/ttactualidad-buffer-posts.json`.

**Medidas de seguridad:** comprobación de `project,event_id,revision` y texto editorial desde `main`; prioridad 1: IA con identidad y SHA-256 validados; prioridad 2: foto de archivo asignada a esa ficha y URL HTTPS pública (respetando los vetos explícitos de derechos); prioridad 3: solo texto. Nunca imágenes asociadas a otra noticia o tendencia ni URLs enviadas desde el móvil; coincidencia exacta de cuenta X en los canales de Buffer; reserva persistente contra doble clic y timeout. Un resultado `unknown` bloquea reenvío hasta verificación humana. Si la imagen IA falla, se intenta foto de archivo; si no hay, se envía solo texto. El botón X tradicional permanece operativo. No se introduce ningún token en el iPhone ni se toca el Worker de Telegram/Instagram.

**Validación:** `.github/workflows/ttactualidad-buffer-tests.yml` incluye pruebas simuladas de los tres modos de imagen, la cuota global y antidualidad sin publicar nada; `.github/workflows/ttactualidad-buffer-ios-verify.yml` compila la app y genera la IPA sin firma `TTActualidad-0.4.64-build76-Buffer-IPA` para PlumeImpactor. No declarar operativa la publicación real hasta que las cuentas estén conectadas y se compruebe una publicación efectivamente `sent` con su texto y con la imagen correcta, cuando exista.

**Restricciones:** Buffer Free tiene límites por cuenta; usarlo no implica publicaciones ilimitadas. En X se deben respetar las restricciones de contenidos repetitivos y de tendencias; aquí existe siempre selección/orden humana individual. No enviar masivamente sin revisar.

### Consumo API (confirmado en documentación oficial de Buffer, 6 de noviembre de 2026)

**NO hay un límite de 1.000 imágenes al mes.** Buffer Free permite **1.000 SOLICITUDES de API por canal desbloqueado dentro de la organización** durante una **ventana móvil de 30 días**, hasta 3.000 solicitudes en total. Dos canales X activos proporcionan una **única bolsa agregada de 2.000 solicitudes / 30 días**, no dos presupuestos independientes de 1.000. Todas las claves API personales y conexiones MCP de la cuenta comparten esa bolsa; el plan gratuito también establece 150 peticiones en 15 minutos y 600 en 24 horas. Las consultas y comprobaciones consumen API igual que las publicaciones. Fuentes: https://developers.buffer.com/guides/api-limits.html y https://support.buffer.com/articles/using-buffers-api-GtIYIQilz5.

**Contador de cuota único compartido**, independiente de los contadores individuales de publicaciones. El backend toma de **las cabeceras de respuestas ya realizadas**, sin ninguna consulta adicional, los campos `RateLimit` y `RateLimit-Policy` de ventana `w=2592000`: cuota total `q`, solicitudes restantes `r`, segundos `t` y fecha de muestreo. Se escriben en `api_quota` del mismo ledger y se leen en la app. Hasta recibir valores reales de Buffer se muestra **«cuota no verificada»**, no una cifra inventada de 2.000.

**Medias diarias dinámicas:** panel global con solicitudes utilizadas y disponibles en 30 días móviles, media actual `utilizadas / 30` peticiones por día y ritmo sostenible `límite / 30` por día (2.000 → aproximadamente 66,7/día cuando haya dos canales). Los paneles de @ttittulares y @ttendenciasesp conservan **publicaciones individuales confirmadas** y añaden conteo 30 días y `publicaciones 30d / 30` como media diaria. Es una media retrospectiva para orientar el ritmo, **no** una fecha de reinicio a fin de mes: no se reinicia el día 1. La cuota real también puede usarse desde otro cliente/MCP, por lo que los recibos de nuestras publicaciones solos no son un medidor global fiable.

**No confundir** 2.000 solicitudes de API con 2.000 publicaciones de X: cada post directo puede consumir varias solicitudes (consultar canales, crear y comprobar el post). Las tres ventanas se aplican conjuntamente. El contador de cuota solo es exacto en el momento de la última respuesta observada.


### Integración de inbox y botón exclusivo de iPhone (6 nov 2026)

La PR #322 ya contiene el historial de la PR #325 y GitHub confirma que se pueden fusionar sin conflictos. El orden es PR #314 → PR #325 → PR #322; la web **no se modifica**. El filtro iPhone de imágenes pendientes conserva el Top 30 actual por ID+revisión, la fecha editorial de corte de noticias y máximo 20 solicitudes visibles. La versión conjunta es **0.4.64 / build76**; conservar la Live Activity, los tests nativos de identidad y la funcionalidad previa.

La publicación directa utiliza el **mismo enlace final y presupuesto de texto X** que el botón tradicional. Primero intenta imagen IA asociada, después foto de archivo de la **misma identidad y revisión** (también si la galería iPhone la reconoce por un archivo bajo `ttittulares/archive-images/` o `trends/archive-images/` aunque el feed no tenga URL), y en ausencia de ambas envía texto solo. Las imágenes de archivo con un veto explícito de derechos se rechazan. No se abre X ni se solicita otra confirmación si el usuario ya pulsó el botón.

El número total de publicaciones confirmadas por Buffer se separa de la **cuota API única y dinámica**. La cuota se mide mediante las cabeceras de Buffer, eligiendo el límite de 30 días por el tamaño de ventana `w=2592000` y emparejando el nombre de la política con su estado, sin depender de que la etiqueta contenga literalmente `30days`. La app muestra también media diaria de solicitudes y medias por cuenta de publicaciones en ventana móvil de 30 días.

**Pendiente para activación:** conectar los canales X a la cuenta Buffer ya existente, guardar `BUFFER_API_KEY` en GitHub Actions Secrets sin compartirla por chat, integrar PRs en orden, probar una publicación real con usuario y revisar contadores y URL. Toda la fase de pruebas previa usa mocks; no se toca el sitio web.
