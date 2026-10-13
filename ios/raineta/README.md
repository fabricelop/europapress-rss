# RainETA para iPhone — v0.3.0

App **nativa SwiftUI / MapKit / ActivityKit** para instalación mediante Impactor en iPhone. Carpeta aislada: `ios/raineta/`. No se modifica la PWA existente y **no utiliza Vercel ni Cloudflare**.

## Cambios v0.3.0 — lugares y continuidad de radar

- **«Mis lugares» en la pantalla principal**: una tarjeta por ubicación, empezando por GPS. Cada una muestra «Ahora», «Próxima lluvia», «Hasta cuándo» y temperatura. Estado actual provisional basado en la salida de Open-Meteo; no se presenta como lluvia observada físicamente.
- **Buscar lugares**: búsqueda geográfica gratuita de Open-Meteo (ciudades/localidades) con selección del resultado.
- **Gestionar favoritos**: guardar coordenada GPS como lugar fijo (no sigue al GPS después), renombrar y borrar. Datos persistidos localmente mediante `UserDefaults`; no se importan automáticamente los favoritos guardados por la PWA web.
- **Seleccionar ubicación**: al tocar una tarjeta, radar, gráfica minuto a minuto, 7 días y Live Activity se refieren a ese lugar (la actividad existente conserva su título hasta que sea recreada).
- **Transición del radar a AHORA**: se conserva el último raster observado hasta que llegue el primer tile nuevo y se mezcla con la proyección futura progresivamente; fuera de la zona de proyección se mantiene un respaldo observado tenue para no vaciar el mapa.
- **Mayor resiliencia**: una tesela periférica del radar que falla no invalida el mosaico entero si la cobertura central está disponible; las teselas transparentes futuras se devuelven como PNG válidos.
- Sin widgets tradicionales, sin App Group, sin despliegue Vercel/Cloudflare. El pipeline genera una IPA para firmar con Impactor.

**Pendiente de paridad completa con la PWA v0.17.18:** consensos multifuente/ensembles, OPERA, rayos, autoevaluación/calibración avanzada de radar, feedback manual «Sí llueve/No llueve», episodios semánticos y búsqueda hasta próxima lluvia. El nuevo resumen rápido usa solo modelos; no debe confundirse con el motor canónico de decisión meteorológica de la web.

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

La acción compila sin firma en macOS el bundle `RainETA.app` con `RainETALive.appex` y genera `RainETA-0.3.0-unsigned.ipa`. La IPA debe firmarse en Impactor; usar Apple ID y mantener la opción de autorrenovación si corresponde.

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
