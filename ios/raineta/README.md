# RainETA para iPhone — v0.2.0

App **nativa SwiftUI / MapKit / ActivityKit** para instalación mediante Impactor en iPhone. Carpeta aislada: `ios/raineta/`. No se modifica la PWA existente y **no utiliza Vercel ni Cloudflare**.

## Cambios de v0.2.0

- **Radar observado + proyección futura 0–240 minutos**: línea temporal cronológica con botón Ahora y saltos +2h/+4h. La pantalla marca expresamente **PROYECCIÓN · NO OBSERVADO**.
- **Motor nativo de desplazamiento** (`RainETA/RadarNowcast.swift`): descarga una cuadrícula geográfica de nueve mosaicos por barrido histórico, compara los dos últimos barridos, estima movimiento con coincidencia de zonas de precipitación y calcula fiabilidad. La proyección (`RainETA/RadarFutureTiles.swift`) desplaza el campo radar en MapKit y reduce gradualmente su opacidad. La zona cargada es limitada; fuera de ella o si faltan datos se conserva el mapa base.
- **Gráfica de 30/60/120 minutos, con una muestra cada minuto.** Son muestras derivadas de advección de radar, NO observaciones ni predicciones independientes por minuto, y la altura representa señal de eco relativa (no mm/h). Si no se puede calcular la proyección, aparece una curva modelizada con interpolación de datos cada 15 min, identificada explícitamente.
- **Previsión 7 días**: 24 h / 72 h / 7 días con precipitación prevista horaria, probabilidad estimada, acumulación diaria y temperaturas mín./máx. via Open-Meteo.
- Mantiene GPS con opción **Siempre**, Live Activity sin widget ni App Group, icono personalizado, e indicación de desactualización.

## Advertencias importantes

- **Proyección experimental**: trasladar ecos no predice su crecimiento/disipación ni garantiza lluvia en tu punto. La fiabilidad decrece con el horizonte, especialmente más allá de 60–90 minutos. La vista hasta 4 h es orientativa y debe compararse con los modelos.
- La gráfica minuto a minuto **no** equivale a un modelo meteorológico con precisión de 1 minuto; no se debe interpretar así.
- RainViewer API: teselas de radar histórico, *máximo nivel zoom 7*. El zoom superior del mapa amplía la rasterización local, sin inventar detalle radar. Se incluye atribución visible y la licencia de uso personal/educativo.
- Live Activities funciona con el iPhone bloqueado, pero iOS no garantiza reconsultas periódicas si la aplicación está suspendida. El estado puede caducar.
- Esta versión NO incluye todavía los 15 modelos/familias del motor web, rayos, detección de evolución física de las nubes ni notificaciones push.

## Compilar IPA

Workflow: [RainETA iPhone IPA](https://github.com/fabricelop/europapress-rss/actions/workflows/raineta-ios.yml)

La acción compila sin firma en macOS el bundle `RainETA.app` con `RainETALive.appex` y genera `RainETA-0.2.0-unsigned.ipa`. La IPA debe firmarse en Impactor; usar Apple ID y mantener la opción de autorrenovación si corresponde.

## Instalación y prueba

1. Descargar y extraer el artefacto de la acción o descargar la IPA desde el chat.
2. Instalar mediante Impactor sobre la versión anterior, sin modificar el identificador.
3. Abrir RainETA, comprobar GPS, seleccionar opción **Siempre** si lo deseas.
4. Abrir radar y arrastrar el control hasta +30/+60/+120/+240 min. Comprobar que el mapa marca proyección.
5. Consultar las gráficas de 30/60/120 min y la vista de 7 días.
6. Activar **En Vivo** y verificar que se sigue mostrando tras bloquear el iPhone.

## Fuentes y atribución

- [RainViewer](https://www.rainviewer.com/) — radar histórico observado, API gratuita para uso personal/educativo.
- [Open-Meteo](https://open-meteo.com/) — modelo 15 min, datos horarios y previsión diaria.
- Apple MapKit y ActivityKit.

Las credenciales y los datos no se envían a servidores propios. Los proveedores remotos pueden imponer límites y condiciones.
