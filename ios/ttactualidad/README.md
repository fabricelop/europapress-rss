# TTActualidad iOS 0.1.0 · SwiftUI / ActivityKit

Aplicación nativa **presupuesto 0 €**, instalada con **PlumeImpactor**. No usa Cloudflare, Workers, Vercel ni Sideloadly para consultar datos.

## Alcance real de esta primera entrega

- TTiTTulares: **Listas** de noticias, con texto desplegable.
- TTendencias: **Top 30** completo por defecto, fecha/hora de la explicación, verde <12 h, ámbar de 12 a 24 h, rojo >24 h, y una sección de **Listas**.
- Contadores del contenido de **Listas**, no del radar, en la app y en una **Live Activity** en pantalla bloqueada y Dynamic Island (si el iPhone la tiene).
- Lectura directa de los JSON públicos de GitHub, respetando decisiones de retirada y últimas revisiones. Caché local y aviso de datos parciales.
- Sin widgets convencionales. La extensión WidgetKit incluye únicamente ActivityConfiguration.
- **Esta primera versión es de consulta**: las operaciones que modifican GitHub (reelaborar, descartar, publicar, añadir noticia) quedan pendientes de autenticación segura. No hay tokens personales embebidos ni acciones falsas.

## Live Activities: actualización realista

La Live Activity se inicia al consultar GitHub, si están autorizadas las actividades en vivo en Ajustes. Se actualiza al abrir o refrescar TTActualidad. Sin APNs con derechos de firma compatibles, iOS no garantiza actualizaciones mientras la aplicación está cerrada o suspendida. La Live Activity enseña la hora de la comprobación e indica datos desactualizados a los 30 minutos; no hay consultas recurrentes en segundo plano.

## Generar e instalar en Windows con PlumeImpactor

1. GitHub > Actions > **TTActualidad iOS - PlumeImpactor IPA** > ejecución correcta.
2. Artifacts > **TTActualidad-0.1.0-PlumeImpactor-IPA**.
3. Descarga y descomprime el archivo ZIP. Dentro está **TTActualidad-0.1.0-PlumeImpactor-unsigned.ipa**.
4. Instala y firma el IPA desde Windows con PlumeImpactor, usando el procedimiento empleado para MiMapaDelTiempo.
5. En el iPhone, permite Live Activities en Ajustes para TTActualidad, abre la aplicación con red y revisa que aparezca la Live Activity con los contadores correctos.

**PlumeImpactor debe firmar tanto TTActualidad.app como la extensión TTActualidadLive.appex.** La compilación sin firmar no demuestra que ActivityKit vaya a funcionar en un dispositivo real; compruébalo tras instalar.

Bundle IDs independientes: com.fabricelop.ttactualidad.native / com.fabricelop.ttactualidad.native.live.

La IPA no necesita mantener encendido el PC para consultar GitHub. No hemos alterado los procesos editoriales ni la integración separada de TTImages.

## Próximas fases

Acciones editoriales directas en GitHub con autenticación segura del usuario y confirmación de escritura; refinamiento del conteo con casos reales; actualizaciones de Live Activity mediante APNs solo si la firma y el presupuesto lo permiten. No incrustar secretos permanentes en la app.
