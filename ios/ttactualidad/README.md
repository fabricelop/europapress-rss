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
