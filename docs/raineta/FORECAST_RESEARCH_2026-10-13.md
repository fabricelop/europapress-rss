# RainETA iPhone — Investigación de previsión futura (13/10/2026)

## Contexto / incidente 0.5.0

Capturas aportadas por el usuario a las 18:12: en el paso de radar observado a +2 horas, la capa ICON-EU aparece lentamente, a veces vacía y a veces con grandes zonas grises/blancas. El control dispone de pasos horarios o botones +2h/+4h, no de los intervalos <=15 minutos solicitados. En +2h puede presentar una hora nominal posterior por el redondeo `ceil` de la hora UTC, sin indicar el desfase real. No se considera funcionalmente aprobado aunque pase la compilación y la prueba de respuesta HTTP PNG.

Causas del diseño:
- Cada cambio de hora destruye/recrea la capa WMS, sin precarga explícita de fotogramas adyacentes ni retención garantizada de las capas con contenido útil.
- El WMS devuelve la paleta propia de ICON-EU, con enormes áreas de color gris; PNG válida NO equivale a visualización útil. Debe comprobarse transparencia, leyenda y clases 0 mm antes de utilizar el estilo.
- La resolución del modelo ICON-EU es ~6 km y su producto TOTPREC01H representa acumulado horario, NO intensidad instantánea ni nowcast de 5 min.
- El control temporal redondea al siguiente punto horario de la fuente y así puede mostrar horas desplazadas respecto a la etiqueta «+2h».
- Tests previos verificaron petición y decodificación PNG a varios zooms, pero no las máscaras de precipitación, bordes de teselas, nitidez visual, cronología auténtica o carga a la vista.

## Fuentes investigadas (no reutilizar imágenes ajenas sin derechos explícitos)

| Fuente | Datos operativos | Paso de tiempo sustentado | España | Integración/coste |
| --- | --- | --- | --- | --- |
| RainViewer Weather Maps API | Radar histórico, NO futuro | observación ~10 min | sí | API de uso personal/educativo, zoom máx. 7, futuro retirado 01/2026 |
| EUMETNET OPERA CIRRUS (ORD API) | Reflectividad compuesta ~1 km | **observación 5 min** | paneuropea, según cobertura radar | API y S3 públicos, ODIM HDF5; **no publica por sí sola predicción futura** |
| EUMETNET OPERA NIMBUS | Intensidad de precipitación / acumulación de lluvia (control de calidad) ~2 km | observación ~15 min para tasa/accum | Europa, según cobertura | API abierta vía MeteoGate; HDF5 |
| Meteocat XRAD + advección STEPS | Radar + **previsión hasta +1 h** | **6 min** | Catalunya, no toda España | ya hacen tres barridos + campo de movimiento + ensemble pySTEPS; comprobar derechos de reutilización API del producto |
| Météo-France PIAF | **nowcast probabilístico combinado** | **5 min hasta +3 h** | cobertura real España por verificar; producto originario francés | API oficial abierta con cuenta, potencialmente gratuita para pruebas; confirmar límites/licencia y cobertura |
| Météo-France AROME-PI | Previsión inmediata numérica | **15 min** | dominio Francia/alrededores: área española por verificar | API con cuenta; py/QGIS proyecto abierto demuestra acceso |
| AEMET HARMONIE-AROME | Campos espaciales mesoescalares de precipitación ~2,5 km, hasta +48h | precipitación horaria publicada en visor | Península/Baleares/Canarias | descarga tar.gz publicada, comprobar archivo, volumen y frecuencia para producción |
| Météo-France AROME HD | Rejilla ~1,3 km para Francia y alrededores | predicciones horarias según paquetes | mapa «Espagne» en Meteociel NO demuestra cobertura peninsular completa | API con cuenta, posibles datos GRIB2/GeoTIFF |
| DWD ICON-EU WMS | Pronóstico horario de precipitación ~6 km | **1 h** | gran parte de Europa | WMS accesible pero latencia, paleta y carga aún no aptos para UI RainETA |
| Open-Meteo | pronóstico por coordenada, punto | 15 min a veces **interpolación horaria** para España | sí | gratuito bajo condiciones; no usar 9x9 como mapa |
| Windy Map Forecast API | mapas incluidos capas precipitaciones | depende del modelo | sí | clave gratuita de pruebas sin capa de lluvia; API pro ~990 €/año, no cumple cero coste |
| Meteoblue | nowcast 5 min y mapas comerciales | 5 min en productos de pago | sí, según producto | versión gratuita no incluye mapas ni resolución de 5 min; no apta para objetivo sin pago |
| Blog WeatherIberia | catálogo histórico de mapas embebidos: Meteociel, Windy, AEMET, IPMA, etc. | depende del proveedor | variado | una imagen embebida o un iframe no constituye un permiso/API para reutilizar |

## Arquitectura elegida, condicionada a pruebas

1. **Ahora / histórico:** producto radar real OPERA/CIRRUS preferentemente, RainViewer de respaldo donde falte. Previsualización de fecha real de cada imagen.
2. **0 a +60 min (objetivo 5/6 min):** usar PIAF donde cubra y se tenga autorización; para España en general, nowcasting STEPS/pySTEPS sobre 3+ barridos radar OPERA/NIMBUS (no advección única), con prueba retrospectiva y fiabilidad cuantitativa. Referencia directa: Meteocat hace esto hoy.
3. **+60 a +180 min:** PIAF donde haya cobertura; fuera, mezcla de advección validada + AROME-PI/HARMONIE según disponibilidad. Si no hay datos de 5/15 min nativos, **presentar pasos gráficos de 15 min rotulados como interpolación**, NO decir «predicción independiente de 15 min».
4. **+3 a +48 h:** mosaicos de campos reales AEMET HARMONIE-AROME 2,5 km en territorio español, modelo alternativo si el proveedor falla.
5. **+48h–7d:** previsión de modelos más amplios y vista de acumulados/probabilidad separada.

### Renderización iPhone
- Descargar/preprocesar campos una vez por ejecución o región, no pedir WMS distinto para cada fotograma visible.
- Mantener dos o más fotogramas en RAM, precargar fotogramas de alrededor y cache en disco con timestamp de modelo y caducidad.
- Usar una sola capa cartográfica continua para el campo numérico, interpolar **valores meteorológicos** cuando haya datos rejilla, no interpolar colores de PNG para simular ciencia.
- Colorear `lluvia=0` y NoData con transparencia real; no pintar el fondo en gris. Escala de 0.1, 0.5, 2, 7.5, 15 mm/h consistente con leyenda.
- El mapa y centro no deben cambiar al alternar radar/modelo. Marcar fuente, hora válida, hora del análisis y nivel de confianza. Si no hay campo válido, dejar observación antigua marcada «solo observado», nunca falsificar futuro.
- Timeline continuo, paso máximo **15 min**; modo 5 min únicamente en tramo con nowcast 5/6 min real o algoritmo validado, intervalo gráfico interpolado claramente marcado.
- Corrección de hora: mostrar hora absoluta del **modelo realmente cargado**. Prever latencia; si +2h solicita +2h48, debe advertirse y ofrecer reanclaje, nunca mostrar falsamente +2 h exactas.

## Tests de aceptación (antes de ofrecer IPA)
- Comparar tres acontecimientos reales/fechas y lugares húmedos/secos. Validación retrospectiva 20/40/60 min frente a observación posterior; error de llegada y falsos positivos.
- Validar máscara de 0 precip y NoData, inexistencia de cobertura gris en zonas secas y continuidad de bordes entre teselas.
- Capturas automáticas pixel a pixel de zoom 7, 9, 12, 16 de un evento real: lluvia visible sin desaparecer ni grandes cuadrados; zoom no añade detalle ficticio.
- Continuidad 0,+5,+10,+15,+30,+60,+120 con gráficos que muestren fuente/cobertura/confianza.
- Instrumentar tiempo hasta primer fotograma, latencia p95 de cambio de hora, peticiones repetidas y ratio de frames no disponibles. Objetivo: cambio cacheado perceptiblemente inmediato y indicador real durante descarga.
- Verificar información para todas las ciudades guardadas y etiqueta clara de la localidad en En Vivo.
- NO considerar test «HTTP 200 devuelve PNG» ni «XCTest sin errores» evidencia suficiente de calidad meteorológica o visual.

## Investigación experimental ejecutada el 13/10 — resultados verificados

- **OPERA directo sin clave:** desde `https://s3.waw3-1.cloudferro.com/openradar-24h/YYYY/MM/DD/OPERA/COMP/OPERA@YYYYMMDDThhmm@0@DBZH.h5`, archivos actuales cada 5 minutos de ~2,3 MB con `dataset1/data1/data` de 4.400 × 3.800 píxeles, reflectividad con `nodata=-9999000` y `undetect=-8888000`. Proyección Lambert Equal Area `+proj=laea +lat_0=55 +lon_0=10 +x_0=1950000 +y_0=-2100000`; resolución de 1 km. Se comprobaron 4 barridos seguidos con datos reales y metadatos de licencia CC BY 4.0.
- **Formato iPhone más prometedor:** `OPERA@YYYYMMDDThhmm@0@DBZH.tiff` existe y fue confirmado con HEAD 200, longitud aproximada de 3,6 MB y `Accept-Ranges: bytes`. Es una GeoTIFF optimizada y evitaría descargar/decomprimir HDF5. Queda probar sus bandas y la capacidad de decodificación de Apple; no asumir que equivale a PNG.
- **Límite API:** MeteoGate respondió HTTP **429** en una repetición; no se debe depender de solicitudes intensivas al catálogo desde cada iPhone. Los nombres S3 deterministas permiten acceso público directo, con estrategia de reintento y caducidad.
- **AEMET HARMONIE archivo oficial:** GET 200 a `https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB`; tar+gzip en streaming, secuencia GeoTIFF por horas de Península/Baleares con bounds `[-11.012,34.488,4.988,44.488]` en EPSG:4326 y 640×400 px. Algunos archivos tienen nombre `down_<fecha-hora>_61_1HH.tif`. Son mapas coloreados / raster con máscaras; **NO** debe interpretarse su banda RGB como mm/h sin confirmar sus metadatos y escala. 10 fotogramas accesibles consecutivos.
- **Primer backtest real** sobre 11 barridos OPERA consecutivos en 16 ciudades europeas prefijadas, 5 y 15 min de horizonte: 12 casos realmente lluviosos, todos en Ámsterdam, Hamburgo y Estocolmo; **ningún caso lluvioso suficiente en las 6 ciudades españolas del test**. El optical flow denso sobre tres barridos ganó F1 a persistencia en 12/12 casos. Mediana F1 +0,0741; mediana de MAE de reflectividad mejora ~1,254 dBZ. Frente a control de suavizado espacial, mediana F1 +0,07315; frente al promedio temporal +0,09935. **No extrapolar a toda España ni a más de 15 minutos**: falta validación de episodios españoles, varias fechas y extrapolaciones más largas.
- **CI reproducible:** `.github/workflows/raineta-radar-feasibility.yml` (formatos/latencia S3), `raineta-radar-science.yml` (HDF y AEMET), `raineta-backtest.yml` (prueba retrospectiva con foto y métricas), `raineta-harmonie-check.yml` (máscaras/GeoTIFF), `raineta-cog-native.yml` (COG directo Apple ImageIO).

### Criterios adicionales antes de la IPA

1. Obtener ≥3 episodios lluviosos distintos en España y ≥2 ciudades de costa/interior, no solo zonas de Europa central.
2. Superar a persistencia **y** suavizado sin movimiento para al menos 5 y 15 minutos en lluvia real española; informar F1, CSI, sesgo y error de llegada.
3. Validar COG Apple ImageIO en una compilación macOS y decodificación/mapa en simulador iOS, además de georreferenciación.
4. Garantizar fuentes/fotogramas explícitos, sin pintar como lluvia zonas sin observación y sin utilizar extrapolaciones más allá del horizonte respaldado.
5. Perfilar batería y consumo de datos de tres barridos COG por ubicación antes de activar descargas en producción.

## Fuentes públicas
- https://weatheriberia.blogspot.com/
- https://meteo.cat/wpweb/divulgacio/equipaments-meteorologics/adveccio-radar/
- https://www.meteo.cat/observacions/radar
- https://www.data.gouv.fr/dataservices/api-modele-arome-prevision-immediate-agregee-fusionnee
- https://github.com/Aleas-territoire/meteole_qgis_plugin
- https://www.eumetnet.eu/observations/weather-radar-network/
- https://eumetnet.github.io/openradardata-documentation/
- https://www.aemet.es/es/eltiempo/prediccion/modelosnumericos/harmonie_arome
- https://catalogo.datosabiertos.miteco.gob.es/catalogo/es/dataset/46e25cfb-d421-425e-8077-1cd7063793a9
- https://open-meteo.com/en/docs
- https://api.windy.com/map-forecast/pricing
- https://business.meteoblue.com/es/productos/weather-apis/free-weather-api
