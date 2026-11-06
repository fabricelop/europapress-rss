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

## Publicación directa en X mediante Buffer Free (opt-in, aún requiere activación)

El botón **«Publicar en X» tradicional NO cambia**: sigue abriendo el compositor de X y conserva la confirmación manual posterior. Se añade **«Publicar directo · Buffer»** en cada noticia o tendencia explicada. El usuario aprueba individualmente tocando ese segundo botón. No existe publicación automática al preparar contenido ni se publica a X desde una tarea programada sin ese toque.

- Canal fijo por proyecto: `ttittulares` → **@ttittulares** y `ttendencias` → **@ttendenciasesp**. La tarea compara el nombre exacto y exige servicio `twitter` antes de enviar; nunca elige una cuenta aproximada.
- Se envía el **texto editorial y exactamente una imagen GAG IA verificada**, obtenidos de `main`, nunca del texto libre recibido por la app. Se exige coincidencia del ID, revisión, explicación y SHA-256 real de la imagen en `ttittulares/site-ai-images.json` o `trends/site-ai-images.json`. Si falta la imagen, no se publica solo texto ni se toma una fotografía con derechos no acreditados.
- La app solo despacha `ttactualidad_buffer_publish_v1` a GitHub mediante la autorización existente. GitHub ejecuta `.github/workflows/ttactualidad-buffer-publish.yml` y `pilot/ttactualidad_buffer_publish.py`. La **API key de Buffer NO entra en la IPA ni en el repositorio**.
- El backend reserva la identidad editorial `(project,event_id,revision)` antes de invocar Buffer: los reintentos no duplican publicaciones. Un error de comunicación tras reservar se marca **unknown** (investigar antes de reintentar; nunca publicar dos veces a ciegas).
- El contador por cuenta se calcula exclusivamente a partir del registro `pilot/ttactualidad-buffer-posts.json`: **total confirmado**, **confirmadas en las últimas 24 horas** (ventana móvil) y **pendientes**. Solo suma estados `sent` confirmados por Buffer; no suma órdenes, posts fallidos ni publicaciones hechas con el botón tradicional. Se sincroniza al abrir, actualizar o recuperar la app.
- El backend vuelve a comprobar los envíos pendientes y solicita el cierre editorial existente al confirmar `sent`; conserva el sistema anterior de decisiones y recibos. El registro es compartido entre instalaciones.
- Si una solicitud a Buffer queda **unknown**, el bloqueo preventivo exige revisión manual del post real antes de liberar ese evento. No borres a ciegas registros de ese tipo.
- La API de Buffer Free tiene límites; no se confunden con el límite diario de publicaciones de X. No se afirma que el contador de Buffer abarque los posts enviados manualmente.

### Activación (solo después de revisar y fusionar la PR)

1. En tu cuenta Buffer, conectar las dos cuentas X: `@ttittulares` y `@ttendenciasesp`. No basta con disponer de cuenta Buffer.
2. Abrir **Buffer → Settings → API**, generar una clave personal y copiarla. **No compartir la clave en ChatGPT ni en el código.**
3. En GitHub, repositorio `fabricelop/europapress-rss` → **Settings → Secrets and variables → Actions → New repository secret**, crear exactamente `BUFFER_API_KEY`. No hay que pagar la API de X ni desplegar otro servidor.
4. Fusionar la PR después de validar CI; obtener la IPA de la acción de iOS y reinstalar la app si procede. Confirmar el dispositivo con un elemento editorial cuyo GAG IA ya esté verificado.
5. Solo después de la verificación real de Buffer `sent` se incrementa el contador. Si no hay cuenta conectada, clave, imagen validada o cuota, el botón nuevo informa del problema y el botón tradicional sigue operativo.

**Seguridad:** publicación solo por una acción humana individual; prohibida la publicación desatendida de tendencias o contenido repetitivo que incumpla las normas de X. El flujo requiere autorización editorial y verificación de la identidad, no un navegador automatizado. Las pruebas se ejecutan con API simulada: nunca publican en X.

