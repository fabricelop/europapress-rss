# RainETA v0.9

PWA estática y móvil para responder a una pregunta: **cuándo empieza y cuándo termina la lluvia en un punto concreto**.

## Motor por horizonte
- **0–2 h:** analiza varios barridos de RainViewer en el navegador. Estima el desplazamiento de la precipitación y proyecta su llegada al punto. El estado “llueve ahora” usa el centro exacto de la muestra de radar; si el movimiento no es suficientemente estable, no inventa una ETA.
- **0–8 h:** añade guía de precipitación a 15 minutos de Open-Meteo, marcada explícitamente como potencialmente interpolada en España.
- **0–72 h:** fusiona deterministas y ensembles. La influencia de ensembles aumenta con el horizonte y la confianza queda limitada progresivamente cuanto más lejos está el episodio.

## Familias de predicción
El consenso actual puede usar hasta 15 capas de modelo, pero la confianza **no** las trata como 15 votos independientes. Agrupa capas correlacionadas por familia antes de calcular acuerdo.

Deterministas:
- ECMWF IFS Europe/HRES ~9 km
- ECMWF AIFS
- DWD ICON seamless
- NOAA GFS
- Météo-France seamless
- CMC GEM
- UK Met Office Global ~10 km

Ensembles:
- ECMWF IFS Europe 51 miembros
- ECMWF AIFS 51 miembros
- DWD ICON-EU EPS 40 miembros
- NOAA GEFS 31 miembros
- UKMO MOGREPS-G 18 miembros
- CMC GEPS 21 miembros
- BOM ACCESS-GE 18 miembros
- Google WeatherNext 2 64 miembros

Familias independientes potenciales: ECMWF, DWD, NOAA, Météo-France, CMC, UKMO, BOM y Google.

## Interfaz v0.4
- Hora exacta de la última actualización de la app, hora del último consenso de modelos y hora del último radar.
- Gráfico de 72 h con eje temporal cada 6 horas, huecos secos y color por probabilidad de lluvia: 35–49 %, 50–69 %, 70–84 % y 85–100 %.
- Temperatura actual.
- Ubicación GPS con feedback manual **Sí llueve / No llueve**. La observación se guarda solo en el dispositivo y, tras suficientes observaciones, calibra el umbral local del radar.
- Lugares guardados con la misma pantalla de detalle y una vista resumen rápida de lluvia actual y temperatura.
- La vista de resumen usa una observación manual reciente para la ubicación GPS cuando existe.

## Interfaz v0.5
- Cuenta atrás en vivo cuando la lluvia está a menos de 2 horas.
- Banda de **0–120 min en pasos de 5 minutos**, combinando proyección radar con guía de precipitación a 15 min.
- La altura de la banda corta refleja señal de precipitación; el color destaca tramos de mayor probabilidad/señal.
- Clasificación orientativa de intensidad: seco, llovizna, débil, moderada o fuerte.
- Mapa base CARTO oscuro para evitar los bloqueos 403 observados con los tiles públicos directos de OpenStreetMap.
- PWA **network-first** con actualización forzada del service worker y assets versionados; la app instalada deja de quedarse fijada en una versión antigua.
- RainETA muestra la versión visible en cabecera para poder comprobar inmediatamente qué build está ejecutando el móvil.
- Autoevaluación radar: cada barrido posterior comprueba previsiones anteriores a 15/30/60/90 min; el histórico local se usa para calibrar gradualmente la confianza cuando ya hay muestra suficiente.

## Interfaz v0.6
- Código de color más contrastado y coherente en 0–120 min y 72 h.
- Regla visual única: **color = probabilidad de lluvia** y **altura = intensidad prevista (mm/h)**.
- Eje de 72 h simplificado a horas sin minutos para evitar solapamientos.
- Temperatura actual más visible.
- Confirmación clara de feedback GPS: botón seleccionado, hora exacta y texto “registrado”.
- Lugares guardados: renombrar y eliminar desde “Mis lugares”.
- Mapa base OpenFreeMap/MapLibre, sin API key ni marca de agua “API key required”.

## Motor de corto plazo v0.7
- La banda 0–120 min ya no puede pintar lluvia antes de la ETA estimada: los bloques de precipitación quedan alineados con el episodio activo.
- RainViewer se decodifica también por **reflectividad dBZ** usando su paleta Universal Blue; ya no se trata solo como máscara eco/no-eco.
- La reflectividad se transforma en una estimación de intensidad (mm/h) y se proyecta junto con el movimiento de la banda.
- La altura de cada bloque corto usa preferentemente intensidad radar a corto plazo y degrada progresivamente hacia la guía de modelos.
- La etiqueta **Seco / Llovizna / Débil / Moderada / Fuerte** se recalcula con la intensidad prevista alrededor de la llegada y cambia con cada nuevo barrido.
- La guía de 15 min de Open-Meteo se conserva como apoyo, pero se reconoce que en Madrid puede estar interpolada desde resolución horaria.

## Radar objetivo
- **EUMETNET OPERA** es el candidato a fuente europea primaria: compuesto de 1 km/5 min con DBZH y tasa de lluvia RATE.
- **AEMET** será una capa oficial específica de España para contraste/regional cuando se gestione una API key renovable.
- **RainViewer** queda como fuente ligera y respaldo visual/nowcasting local.

## Interfaz y motor v0.8
- El resumen superior deja de duplicar la cuenta atrás: muestra la **hora prevista** de inicio; la cuenta atrás en vivo queda solo en 0–120 min.
- La ETA de corto plazo se estabiliza con los últimos barridos radar: un único barrido atípico no mueve por sí solo toda la previsión; la app muestra además cuándo la ETA ha sido revisada.
- Tarjeta superior, banda 0–120 min y episodios comparten la misma ETA canónica para evitar contradicciones visuales.
- La velocidad del radar se etiqueta como **desplazamiento del eco de precipitación**, no viento.
- Las barras de 72 h son interactivas. Al tocarlas, la tarjeta 0–120 min cambia a detalle de esa hora con estado meteorológico, temperatura, probabilidad, intensidad, nubosidad, nieve y confianza.
- La lógica de 72 h y la de Episodios usan el mismo clasificador. Las señales marginales quedan como barras tenues y no se convierten automáticamente en episodios continuos.
- Los episodios muestran duración, carácter (persistente/variable/por pulsos), lluvia total estimada, pico, probabilidad media/máxima, familias independientes, ventana probable de inicio y ventana seca posterior.
- El control de radar recorre hasta ~2 h históricas reales y hasta +120 min de **proyección por movimiento**. La parte futura se etiqueta explícitamente como extrapolación, no observación.

## Coherencia v0.9
- Las primeras 2 horas del gráfico de 72 h se reconstruyen con el mismo nowcast canónico de 5 minutos que alimenta la tarjeta superior; no se muestran señales horarias crudas que contradigan la ETA.
- “Episodios previstos” se recalcula sobre esa línea temporal canónica y añade detalle **hora por hora** con estado, probabilidad e intensidad.
- El radar incorpora un botón **AHORA** para volver inmediatamente al último barrido observado.
- Se añade backend `/api/rain-opera` con caché CDN para descubrir el último compuesto EUMETNET OPERA NIMBUS RATE (1 km / 5 min) sin consumir una consulta MeteoGate por dispositivo.
- El backend ya muestrea el COG `RATE` en la coordenada solicitada, devuelve mm/h + calidad del píxel y puede actuar como evidencia independiente de lluvia actual cuando el barrido está fresco.

## Radar
RainViewer aporta los últimos barridos. RainETA descarga una imagen centrada en la ubicación, genera una máscara de precipitación en el dispositivo, calcula traslación entre barridos y proyecta el píxel de la ubicación cada 5 minutos hasta 120 minutos.

El radar se refresca cada 5 minutos mientras la PWA está visible; los modelos se cachean durante 20 minutos para no malgastar ancho de banda ni CPU.

## Arquitectura y coste
RainETA no añade ninguna Serverless Function al proyecto Vercel. Las consultas se realizan directamente desde el navegador a APIs públicas con CORS y el nowcasting se ejecuta en el dispositivo. Esto evita el límite de funciones del plan Hobby y reduce Fluid Active CPU.

## Fuentes
- Open-Meteo Forecast / Ensemble / Geocoding.
- RainViewer Weather Maps API.
- OpenFreeMap/MapLibre para mapa base, con datos © OpenStreetMap contributors y sin API key.

AEMET OpenData queda como futura capa adicional. Requiere API key y no se embebe una clave privada en una PWA pública. El radar español ya participa indirectamente cuando está incluido por el agregador de radar utilizado, pero RainETA no lo presenta como una conexión AEMET directa mientras no exista esa integración.

## Principios de precisión
- No mostrar una hora “exacta” cuando los datos no la justifican.
- Diferenciar observación radar de pronóstico.
- Penalizar el desacuerdo entre familias independientes.
- Reducir el máximo de confianza con el horizonte.
- Priorizar alta resolución regional/europea antes que sumar modelos de peor calidad solo para aumentar el contador.
- Degradar de forma funcional si falla una fuente.

## Tests
El CI valida:
- sintaxis de los módulos cliente;
- consenso y detección de episodios;
- movimiento/proyección de radar con máscaras sintéticas;
- calibración de confianza por familias;
- disponibilidad real de modelos, ensembles, radar y geocodificación.
