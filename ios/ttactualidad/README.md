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



## TTActualidad iPhone 0.4.62 build74 — publicación directa Buffer Free (propuesta aislada)

**Base técnica:** app moderna 0.4.61 build73 de la rama `feature/ttactualidad-relations-recent-inbox-20261105` (PR #314). **No usar la versión antigua del README/IPA 0.2.0 para esta función.** Esta implementación se mantiene como PR dependiente sin reemplazar las funciones de relaciones, imágenes, edición, histórico, pendientes ni Live Activities.

**Dos acciones completamente independientes:**
- «Publicar en X»: **sin cambios**; abre el compositor X con el texto preparado, conserva la foto manual y las decisiones posteriores.
- «Publicar directo · Buffer»: un toque individual desde una ficha **en Listas**, siempre que tenga texto e imagen IA verificada; transmite una solicitud editorial autenticada a GitHub. No abre X y asigna rígidamente @ttittulares a noticias y @ttendenciasesp a tendencias. No publica por sí sola al generar o elaborar una noticia.
- En el panel aparecen dos nuevos contadores **DIRECTAS X** independientes de los actuales «24 h publicados»: total confirmado en X por Buffer, confirmados durante 24 h móviles, y operaciones pendientes. Un HTTP 204, post reservado, en cola, fallido o de estado incierto **no aumenta** el contador.
- Cierre de Listas a través del mismo flujo GitHub `ttactualidad_action_v1` solo **después** de confirmación real del estado `sent` del post por Buffer. Los eventos manuales existentes y su histórico no se alteran.

**Credenciales y puesta en marcha (sin coste añadido):** el usuario ya tiene una cuenta Buffer, pero debe conectar dentro de Buffer las **dos cuentas X** y generar su API key. En GitHub, repositorio → Settings → Secrets and variables → Actions, debe guardar la clave como secreto `BUFFER_API_KEY`. Jamás introducirla en la app, en un chat o en un commit. Conexión de X o secreto ausentes → bloqueo seguro, sin envío. La publicación está implementada en `pilot/ttactualidad_buffer_publish.py` y `.github/workflows/ttactualidad-buffer-publish.yml` (solo ejecutables tras fusionar el código a main); lecturas y estado en `pilot/ttactualidad-buffer-posts.json`.

**Medidas de seguridad:** comprobación de `project,event_id,revision` y texto editorial desde `main`; imagen GAG IA bajo `generated-images` coincidente con la ficha y SHA-256 verificado, nunca una imagen de archivo ajena ni una URL arbitraria; coincidencia exacta de cuenta X en los canales de Buffer; reserva persistente contra doble clic y timeout. Un resultado `unknown` bloquea reenvío hasta verificación humana. El fallo de una imagen deja operativo el botón X tradicional. No se introduce ningún token en el iPhone ni se toca el Worker de Telegram/Instagram.

**Validación:** `.github/workflows/ttactualidad-buffer-tests.yml` contiene seis pruebas simuladas sin publicar nada; `.github/workflows/ttactualidad-buffer-ios-verify.yml` compila la app y genera la IPA sin firma `TTActualidad-0.4.62-build74-Buffer-IPA` para PlumeImpactor. No declarar operativa la publicación real hasta que las cuentas estén conectadas y se compruebe una publicación efectivamente `sent` con su foto.

**Restricciones:** Buffer Free tiene límites por cuenta; usarlo no implica publicaciones ilimitadas. En X se deben respetar las restricciones de contenidos repetitivos y de tendencias; aquí existe siempre selección/orden humana individual. No enviar masivamente sin revisar.
