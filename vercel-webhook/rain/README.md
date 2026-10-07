# RainETA v0.17.34

PWA estática y móvil para responder a una pregunta: **cuándo empieza y cuándo termina la lluvia en un punto concreto**.

## Proyección radar sintética y rayos DWD v0.17.34
- La proyección futura deja de usar por completo el PNG de RainViewer como textura. Se reconstruye desde la matriz interna de precipitación (mask + rateGrid) que RainETA ya decodifica para el nowcast; los píxeles no húmedos nacen transparentes y no pueden formar un rectángulo de fondo.
- La paleta futura se regenera desde la intensidad mm/h estimada y luego se deforma con el flujo óptico local. El observado sigue usando RainViewer original; solo el futuro se sintetiza.
- La capa eléctrica usa dos fuentes DWD simultáneas: `dwd:Accumulated_Flash_Geometry` (geometría acumulada 5 min del MTG Lightning Imager) y `dwd:NCEW_EU` (NowCastELEC, polígonos alrededor de rayos detectados y pronosticados).
- La UI ya no afirma que la capa funciona solo por haber pulsado ON: escucha eventos de carga/error de MapLibre y muestra `cargando`, `activos` o `error cargando DWD`.


## Transparencia radar y rayos operativos v0.17.33
- La proyección local ya no reutiliza el bitmap completo del radar: antes de mover celdas, RainETA elimina todos los píxeles que no correspondan a reflectividad de precipitación reconocida. Esto evita el rectángulo negro opaco visto al pasar de AHORA a +1 min.
- Si más del 75% del bitmap resultara clasificado como precipitación, la proyección se rechaza por seguridad en lugar de pintar un fondo defectuoso.
- La capa de rayos usa el WMS público de DWD para el producto MTG Lightning Imager Accumulated Flash Area de EUMETSAT, en acumulaciones de 5 min.
- El estado de rayos queda explícito en pantalla: desactivado, activo cerca de AHORA u oculto fuera de contexto. Si la capa está activa y no aparecen trazas, la interfaz indica que no hay actividad visible en esa zona.


## Estabilización espacial del flujo local v0.17.32
- Al combinar varios barridos, los vectores locales se agrupan por su coordenada real de rejilla. Si una zona desaparece por baja confianza en un barrido, ya no se empareja accidentalmente con la siguiente zona de la lista.
- Cada vector conserva persistencia y número de muestras; los vectores vistos en varios barridos ganan estabilidad y los aislados pierden peso.
- Se añade una prueba de regresión específica para impedir que reaparezca este cruce de celdas.


## Rayos EUMETSAT v0.17.31
- El mapa incorpora un botón opcional `⚡ RAYOS` basado en Meteosat Third Generation Lightning Imager (EUMETSAT), capa de actividad eléctrica acumulada en 5 min.
- La capa solo se muestra cerca de AHORA (últimos 5 min). Al navegar a radar histórico más antiguo o a proyección futura se oculta automáticamente para no mezclar tiempos distintos.
- EUMETSAT es la fuente observada principal para actividad eléctrica. La red terrestre de AEMET queda preparada como contraste adicional cuando exista una API key de AEMET en el backend.
- Blitzortung no se usa como fuente cruda porque sus datos no constituyen una API pública general para redistribución en aplicaciones de terceros.


## Nowcast espacial por células v0.17.30
- El radar futuro deja de trasladar toda la imagen con un único vector global.
- RainETA conserva el campo de flujo óptico local ya calculado sobre los últimos barridos y proyecta una malla 16×16: cada zona/célula se desplaza según los vectores locales interpolados.
- El flujo local se estabiliza progresivamente con viento atmosférico a 850/700 hPa cuando radar y viento son coherentes, siguiendo el mismo principio general usado por nowcasts modernos como Ventusky.
- El horizonte espacial es dinámico y nunca supera 60 min: depende de cobertura/calidad del flujo local, acuerdo radar-viento y señal convectiva (CAPE, probabilidad de tormenta/actividad eléctrica).
- Si no hay flujo local defendible, RainETA corta el campo futuro; no vuelve al antiguo desplazamiento rígido global.
- La intensidad/forma no se hace crecer artificialmente. Más allá del horizonte espacial manda HARMONIE y el consenso de modelos para ETA/probabilidad.


## UI estable simplificada v0.17.29
- «Tiempo estable» queda como único titular principal del estado estable; la etiqueta superior pasa a «Previsión actual».
- El chip de estado actual usa «Ahora: sin precipitación» para evitar repetir el mismo texto en varias zonas.
- La línea técnica deja de repetir la conclusión meteorológica y muestra solo Radar / OPERA / Modelos.
- Las posibles llegadas OPERA solo se enseñan en esa línea si caen dentro del horizonte fiable del propio nowcast; señales más lejanas se ocultan como información no accionable.


## ETA radar exige precipitación medible v0.17.28
- RainViewer, OPERA y AEMET ya no pueden generar una «próxima lluvia» solo por movimiento/ocupación del eco: el episodio debe contener precipitación medible alrededor de la llegada.
- Un candidato radar ordinario requiere al menos dos pasos consecutivos con tasa >= 0,05 mm/h y fracción húmeda >= 0,10, o una señal fuerte con pico >= 0,30 mm/h.
- Las señales marginales (<0,12 mm/h de pico) se descartan si los modelos tampoco apoyan precipitación y la confianza radar no es alta.
- La capa de decisión vuelve a validar los eventos fusionados antes de convertirlos en ETA. Un evento sin evidencia cuantificable se elimina y deja paso al estado estable/modelos.
- Esto evita situaciones incoherentes como «empieza a las 20:00» mientras la propia banda muestra 0,0 mm/h y el gráfico de 24 h permanece vacío.


## Estado estable separado del horizonte radar v0.17.27
- El final del horizonte fiable del radar deja de convertirse en un falso «hasta HH:MM». Ese límite queda únicamente como dato técnico de nowcast.
- Si no existe una ETA real de lluvia, el estado principal pasa a «Tiempo estable» y usa una ventana meteorológica de 3/6/12/24 h derivada del consenso de modelos.
- La ventana estable exige cobertura temporal suficiente, ausencia de episodios clasificados como lluvia y riesgo máximo compatible con cada horizonte; no se extiende a 24 h si las señales son demasiado inciertas.
- El contador corto deja de contar hacia el fin del radar cuando no hay cambio meteorológico previsto. En estado estable muestra directamente el horizonte validado (por ejemplo, 24 h).
- El titular, la banda de 0–180 min y el gráfico de 24 h comparten ahora la misma conclusión meteorológica para evitar contradicciones visuales.
- La redacción principal evita «Seco»: usa «Tiempo estable», «Sin lluvia prevista…» y mantiene «radar útil ~N min» como información secundaria.


## Frescura real y aprendizaje AEMET v0.17.26
- HARMONIE-AROME deja de marcarse fresco por el mero hecho de responder: RainETA valida la hora real de generación (sourceGeneratedAt) de la pasada oficial.
- Una pasada HARMONIE que supere su cadencia de 6 h más 3 h de gracia queda fuera del consenso hasta que AEMET publique una salida nueva.
- El radar AEMET entra en la autoevaluación local 15/30/60/90/120 min junto a RainViewer, OPERA y modelos.
- La verdad automática para evaluar fuentes usa mayoría entre los radares disponibles; la observación manual del usuario sigue teniendo prioridad.
- El acierto local de AEMET puede limitar la confianza de sus ETA cuando exista muestra suficiente, evitando mantener pesos fijos si una fuente rinde peor en una ubicación concreta.


## Radar AEMET con autoridad operativa v0.17.25
- El radar oficial AEMET deja de ser solo diagnóstico: participa en lluvia actual, ETA de corto plazo, horizonte fiable y ventanas secas.
- Una señal ordinaria de lluvia actual requiere acuerdo de al menos dos entre RainViewer, OPERA y AEMET; una señal muy intensa de una sola fuente puede confirmar lluvia por sí misma.
- El nowcast AEMET entra en la mezcla 0–180 min, junto con RainViewer/OPERA, sin convertir tres radares correlacionados en tres familias de modelos independientes.
- AEMET se refresca junto a las demás fuentes radar y puede corregir tanto llegadas como pausas/reanudaciones.
- Fuera del horizonte espacial defendible el mapa sigue sin inventar ecos futuros; la ETA pasa a HARMONIE-AROME y consenso multimodelo.
- El smoke de CI verifica además la disponibilidad viva de las descargas oficiales AEMET de radar y HARMONIE antes de aceptar la rama.

## Motor por horizonte
- **0–4 h:** la banda corta mantiene su detalle 0–180 min, mientras el mapa radar puede avanzar visualmente hasta 4 h. El radar solo tiene autoridad dentro de su horizonte fiable dinámico; después el peso cae a cero y mandan modelos/consenso.
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

## Interfaz v0.10
- El bloque de feedback GPS “¿Está lloviendo donde estás?” se mueve debajo del radar.
- El gráfico principal permite elegir 24 h, 48 h o 72 h; la elección se guarda en el dispositivo.
- Episodios previstos muestra una tabla horaria legible con columnas Hora / Tiempo / Prob. / Intens.
- “Tormenta” deja de sustituir a la intensidad de precipitación: la fila puede mostrar, por ejemplo, `Llovizna` y debajo `Tormenta prevista`.

## Episodios semánticos v0.11
- Un episodio largo se presenta como **ventana meteorológica**, no como lluvia continua.
- Cada episodio se divide en tramos consecutivos comprensibles: tramo más probable, llovizna intermitente, lluvia débil, chubascos aislados, riesgo bajo/intermitente o precipitación con riesgo de tormenta.
- Cada tramo muestra intervalo horario, probabilidad media e intervalo de intensidad.
- El detalle hora a hora sigue disponible, pero plegado para que la lectura principal sea más rápida.
- Entre episodios se muestran **ventanas secas probables** con duración e intervalo horario.

## AEMET HARMONIE-AROME oficial v0.17.22
- RainETA incorpora como familia independiente el modelo oficial AEMET HARMONIE-AROME para Península y Baleares.
- El backend descarga la última pasada pública de AEMET, un paquete tar.gz, y procesa únicamente los 48 GeoTIFF horarios de precipitación 61_1HH.
- Cada GeoTIFF está en EPSG:4326 a 0,025° (~2,5 km). RainETA muestrea el punto seleccionado y una vecindad de 5×5 celdas (~12,5 km) para conservar información espacial útil sin confundirla con probabilidad.
- La precipitación oficial se publica en clases RGBA; el backend traduce las clases visibles a un valor representativo. La clase transparente 0–0,5 mm se trata conservadoramente como inferior al umbral de onset, porque el producto no permite distinguir cero de llovizna sub-0,5 mm.
- HARMONIE-AROME entra en el consenso con familia AEMET y peso determinista alto. Sigue contrastado con ECMWF, ICON, UKMO y ensembles; no sustituye el consenso a ciegas.
- La descarga de ~28 MB se cachea en memoria y la respuesta de punto lleva caché CDN. No se expone ningún secreto y este producto público no necesita API key.
- La caché meteorológica cambia a consensus-v14 para forzar un recálculo real al incorporar la nueva fuente.

## Horizonte espacial honesto v0.17.21
- La proyección cartográfica del radar se corta al superar el horizonte que el nowcast puede defender. A partir de ese punto RainETA deja el mapa sin ecos futuros en vez de congelar o desplazar artificialmente la última imagen.
- Si el movimiento radar no supera los controles de confianza/estabilidad, no se dibuja ninguna trayectoria futura.
- La ETA y la probabilidad siguen funcionando con el consenso de modelos; el corte afecta únicamente al campo espacial de radar.
- Este comportamiento es transitorio hasta sustituir la extrapolación larga por un campo futuro híbrido radar + NWP de alta resolución.

## Navegación frame a frame e histórico ampliado v0.17.20
- El radar incorpora botones ◀ / ▶ para inspeccionar manualmente cada paso. En el tramo observado saltan únicamente entre barridos reales; en el futuro avanzan o retroceden minuto a minuto.
- Cualquier pulsación manual detiene la reproducción automática para que el usuario pueda comparar dos frames consecutivos sin interferencias.
- La interfaz identifica explícitamente OBSERVADO o PROYECCIÓN, el número de frame observado y la hora exacta.
- El histórico observado admite hasta 240 min. Como la API pública de RainViewer solo entrega unas 2 h en cada consulta, RainETA conserva localmente los barridos ya vistos y los fusiona en una ventana móvil de hasta 4 h, sin fabricar imágenes ausentes.
- El archivo local se limita a 4 h y se recorta automáticamente. La integración posterior de radar oficial podrá rellenar directamente ese horizonte cuando la fuente lo permita.

## Continuidad y control físico del radar v0.17.19
- Se descarta la deformación afín experimental de v0.17.18: el radar futuro no crece, encoge ni se cizalla por una regla visual inventada.
- El primer fotograma futuro conserva exactamente la huella geográfica del último radar observado. RainViewer entrega las imágenes de 512 px como una representación de alta resolución de una tesela lógica de 256 px; RainETA usa ahora esa huella lógica para evitar el salto de escala AHORA → +1 min.
- Las coordenadas de la imagen futura se calculan en Web Mercator, igual que las teselas observadas, evitando aproximaciones de latitud/longitud que podían introducir desplazamientos.
- Una traslación radar superior a 180 km/h se rechaza como físicamente no fiable en vez de convertirse en trayectoria futura.
- La proyección visual exige además confianza y estabilidad mínimas. El flujo local solo corrige el global cuando ambos tienen rumbo y velocidad razonablemente coherentes; nunca puede dominarlo.
- Fuera del horizonte fiable la distancia adicional queda amortiguada y termina estabilizándose; no se inventa crecimiento de la mancha.
- Esta base prepara la incorporación de fuentes espaciales de mayor calidad (AEMET/OPERA/modelos de alta resolución) sin mezclar todavía campos incompatibles.

## Radar futuro más visible v0.17.17
- La pérdida de opacidad fuera del horizonte fiable se reduce de forma importante: la proyección sigue claramente visible aunque ya sea orientativa.
- Dentro del horizonte fiable la capa mantiene un contraste alto; al salir de él baja de forma gradual, pero conserva aproximadamente un 30 % de opacidad incluso cerca de +4 h.
- Cuando no existe movimiento suficientemente fiable, el último radar también permanece más visible como referencia espacial en vez de desvanecerse casi por completo.
- La indicación textual de que la proyección es orientativa se mantiene, pero la visualización deja de ocultar información que el usuario ya sabe interpretar con cautela.
- Este ajuste es exclusivamente visual y no modifica ETA, nowcast ni confianza meteorológica.

## Coherencia de horizonte, cobertura radar y carga v0.17.16
- Si el radar solo puede garantizar tiempo seco hasta el final de su horizonte fiable, la interfaz ya no dice **“Seco hasta”** como si esa hora fuera una ETA de lluvia. Muestra **“Seco al menos hasta”**, indica “sin ETA de lluvia” y explica que la hora es un límite de confirmación.
- La banda 0–180 min aplica la misma semántica: la cuenta atrás representa el mínimo tiempo seco confirmado, no una llegada prevista.
- La proyección futura del mapa deja de usar siempre una imagen estática a zoom 7 (demasiado recortada para la vista de España). El zoom de la imagen se adapta al zoom **y al tamaño real del viewport**, abriendo uno o más niveles cuando hace falta, con un mínimo de zoom 5, para conservar la precipitación que ya se veía al pasar de AHORA a +5 min.
- Al cambiar el zoom del mapa durante una proyección futura, la imagen se recalcula con la cobertura adecuada.
- La caché meteorológica queda separada de la versión puramente visual de la app mediante un **schema de consenso**. Las versiones 0.17.13–0.17.16 son compatibles entre sí y no fuerzan una descarga completa solo por un cambio de interfaz.
- Un refresco manual conserva la última previsión visible mientras consulta las fuentes nuevas; deja de vaciar la cabecera con “Calculando…” durante toda la espera.

## Desvanecimiento continuo del radar v0.17.15
- La proyección futura deja de cambiar de opacidad por escalones fijos; el radar se desvanece con una **curva continua** dependiente de minutos, confianza y estabilidad de la evolución.
- Dentro del horizonte fiable la capa conserva suficiente contraste, pero pierde presencia gradualmente conforme aumenta la incertidumbre.
- Fuera del horizonte fiable la opacidad cae exponencialmente hasta un mínimo visual muy tenue al acercarse a +4 h; la ETA sigue dependiendo de modelos/consenso.
- Si no hay movimiento radar fiable, el último barrido se mantiene fijo como referencia pero parte de una opacidad mucho menor y se desvanece todavía más con el horizonte.
- El cambio es exclusivamente visual: no modifica nowcast, ETA, eventos ni pesos meteorológicos.

## Calibración local por origen v0.17.14
- La confianza de corto plazo deja de usar indiscriminadamente el historial de RainViewer: cada tipo de evento se calibra con su **propia fuente**.
- Los eventos RainViewer usan su autoevaluación radar histórica, pero de forma conservadora: el historial solo puede **limitar** una confianza actualmente alta, nunca elevar una señal meteorológica débil.
- Los eventos OPERA usan únicamente el historial local de OPERA; los eventos de modelos usan únicamente el historial local de Modelos.
- La fusión RainViewer+OPERA solo usa aprendizaje local cuando ambas fuentes tienen muestra suficiente.
- Todas las fuentes aplican una regla deliberadamente conservadora: un historial local pobre puede **limitar** la confianza, pero un historial bueno no la eleva artificialmente por encima de la confianza meteorológica calculada.
- Esta corrección evita que un radar con buen/mal rendimiento local contamine la confianza mostrada para una ETA que en realidad procede de modelos.

## Coherencia interna de familias v0.17.13
- El acuerdo ya no se mide solo entre las medias de familias meteorológicas: RainETA compara también, cuando existen ambos, el **determinista y el ensemble de una misma familia**.
- Si una familia muestra contradicción fuerte (por ejemplo, determinista húmedo y ensemble mayoritariamente seco), esa tensión reduce el acuerdo efectivo y por tanto la confianza temporal.
- La corrección es deliberadamente moderada: el desacuerdo interno puede reducir la componente de acuerdo hasta un 35 %, pero no modifica directamente la probabilidad ni la cantidad de precipitación.
- El gráfico conserva el porcentaje de desacuerdo interno por hora y los episodios guardan su media; si supera ~20 %, el panel de Fuentes y el episodio lo muestran como **conflicto det↔ens**.
- Esta señal evita falsos “consensos” producidos por promediar primero dos productos contradictorios de la misma familia.

## Frescura no verificable v0.17.12
- Una caída de la metadata de actualización ya no se interpreta como modelo obsoleto: la previsión sigue utilizándose si el dato meteorológico responde.
- Sin embargo, si la frescura queda **no verificable** en una parte importante de las familias activas, RainETA reduce suavemente la confianza temporal en vez de comportarse como si todos los runs estuvieran confirmados.
- Hasta un 25 % de familias con metadata no verificable no penaliza el consenso; por encima de ese umbral la penalización crece progresivamente hasta un máximo de **6 puntos**.
- La penalización por metadata no verificable se suma a la de runs todavía propagándose, con un límite conjunto de **12 puntos**. Probabilidad e intensidad previstas no se modifican.
- Si dentro de una familia existe al menos un producto con frescura verificada, esa familia no se considera desconocida.
- El panel Fuentes indica cuántas familias tienen frescura no verificable y la reducción total de confianza aplicada.

## Propagación segura de runs v0.17.11
- La metadata de Open-Meteo distingue ahora un run recién publicado de un run ya estabilizado entre servidores.
- Durante los primeros **10 min** desde `last_run_availability_time`, el modelo sigue siendo utilizable pero aparece como **EN PROPAGACIÓN**; no se confunde con un run obsoleto ni con frescura plenamente verificada.
- Si una familia dispone simultáneamente de otro producto con run estable, la familia se considera estable y no recibe penalización por el producto que aún se está propagando.
- Si varias familias activas están todavía propagándose, RainETA reduce de forma suave la **confianza temporal** (máximo 8 puntos según proporción), sin alterar probabilidad ni cantidad de precipitación.
- El panel Fuentes muestra cuántas familias están propagándose y la penalización aplicada. Mientras exista propagación, la caché de previsión baja temporalmente de 20 a **5 min** para reevaluar pronto; una vez estabilizados los runs vuelve al TTL normal.
- La regla sigue la recomendación pública de Open-Meteo de esperar unos 10 min tras la disponibilidad para asegurar consistencia entre sus servidores redundantes.

## Curvatura radar limitada por tendencia v0.17.10
- RainETA guarda localmente una serie corta del **rumbo y velocidad** derivados de los barridos radar recientes para detectar si la advección está girando de forma persistente.
- La curvatura visual solo se activa con al menos **3 observaciones**, ≥10 min de historial, confianza suficiente y giro con signo consistente; cambios bruscos o incoherentes se descartan como ruido.
- El giro extrapolado queda limitado a una tasa razonable y a un ajuste medio máximo de **±8°**. No modifica la ETA ni el algoritmo meteorológico: únicamente evita que la imagen proyectada avance siempre en una recta perfecta cuando el propio radar muestra un cambio de rumbo sostenido.
- El ajuste deja de crecer al alcanzar el horizonte radar fiable (y como máximo tras 60 min). A partir de ahí se mantiene el rumbo limitado mientras siguen actuando la desaceleración, dispersión y pérdida de opacidad existentes.
- Sin evidencia suficiente de giro, la proyección permanece exactamente en el modo lineal amortiguado de v0.17.3.
- El texto del radar indica cuando se está aplicando una tendencia reciente de giro, siempre como **ajuste limitado**.

## Fallback explícito de previsión v0.17.9
- Si caduca la caché normal y **ninguna fuente nueva de previsión responde**, RainETA puede reutilizar durante un máximo de **90 min** la última previsión válida de la misma versión y ubicación.
- El fallback nunca es silencioso: la cabecera muestra **MODO DEGRADADO**, la edad de la previsión y cuántas capas siguen realmente vivas.
- Los modelos reutilizados dejan de contar como fuentes sanas y el panel Fuentes los identifica como “última previsión válida · sin actualización en vivo”.
- La confianza temporal de la previsión guardada queda limitada por edad: máximo 55 % hasta 45 min, 45 % hasta 70 min y 35 % después.
- Radar RainViewer y OPERA se refrescan independientemente; si siguen vivos pueden mantener autoridad en el corto plazo aunque los modelos estén en fallback.
- Una guía de 15 min guardada no vuelve a contarse como viva si su refresco falla. Solo se recupera su estado saludable cuando responde de nuevo.
- El fallback no cruza versiones de RainETA: después de cambiar el motor se exige al menos una previsión fresca de esa versión antes de poder reutilizarla.
- Durante MODO DEGRADADO no se crean nuevas muestras de acierto para **Modelos** a partir del forecast reciclado; RainViewer/OPERA sí pueden seguir aprendiendo si sus datos en vivo están disponibles.

## Elección adaptativa entre radares v0.17.8
- Cuando RainViewer y OPERA discrepan más de 30 min en la ETA, RainETA ya no depende solo de la confianza instantánea si existe suficiente historial local de verificación.
- La autoevaluación local 0–2 h se usa únicamente cuando **ambas** fuentes tienen muestra suficiente y su diferencia de acierto es de al menos 8 puntos porcentuales; así se evita sobreajustar con pocas observaciones.
- En ese caso la elección combina 72 % de confianza instantánea y 28 % de acierto local; el desacuerdo sigue penalizando la confianza final y ensanchando la incertidumbre.
- Si no hay historial suficiente, el comportamiento permanece conservador: se prioriza la fuente con mayor confianza instantánea.
- La explicación de ETA indica explícitamente si la prioridad vino del histórico local o de la confianza instantánea.

## Frescura de runs meteorológicos v0.17.7
- RainETA consulta la metadata pública de actualización de Open-Meteo para los modelos donde existe una correspondencia de dominio fiable.
- Un modelo cuya metadata confirme que ha superado su cadencia normal de actualización más **20 min de gracia** queda marcado como **DESACTUALIZADO** y se excluye del consenso y del recuento de fuentes sanas.
- Si la metadata falla, es parcial o Open-Meteo no publica una correspondencia exacta (por ejemplo el producto ECMWF ENS Europe nativo), RainETA usa estado **frescura no verificable** y no elimina el modelo a ciegas.
- En modelos *seamless* con varios dominios de respaldo, basta con que uno de los dominios monitorizados esté actualizado para mantener el producto operativo; solo se declara stale cuando todos los dominios comprobables están retrasados.
- El panel Fuentes muestra el run verificado o el retraso detectado. Las consultas de metadata son ligeras y no añaden funciones Vercel.

## Quórum mínimo de modelos v0.17.6
- Una señal ordinaria respaldada por **una sola familia meteorológica** ya no crea por sí sola un episodio de lluvia con ETA: se degrada a riesgo posible.
- Con una sola familia, RainETA solo conserva el estado de lluvia prevista cuando la señal es excepcionalmente fuerte (precipitación esperada ≥0,35 mm/h o probabilidad ≥90 % con ≥0,15 mm/h).
- Con dos o más familias independientes el clasificador conserva sus umbrales normales; la confianza sigue limitada por la diversidad disponible.
- Esta protección actúa especialmente durante caídas parciales de proveedores: evita convertir la coincidencia interna de una única familia en falso consenso.
- Cuando la confianza temporal cae, las ventanas probables de **inicio y fin** se ensanchan automáticamente; RainETA evita mostrar un intervalo estrecho si la diversidad de fuentes o el horizonte no justifican esa precisión.

## Confianza por familias independientes v0.17.5
- El consenso deja de poder mostrar confianza alta cuando sobreviven muy pocas **familias meteorológicas independientes**, aunque las fuentes restantes coincidan entre sí.
- La confianza temporal queda limitada progresivamente por el número de familias disponibles: con 1–2 familias el máximo es bajo/moderado; con 4–6 familias puede alcanzar niveles altos si además hay acuerdo y horizonte favorable.
- Los miembros de un ensemble y las variantes determinista/ensemble de una misma familia no cuentan como fuentes independientes adicionales.
- El panel de diagnóstico muestra cuántas familias independientes están realmente activas y cuántos modelos/ensembles respondieron, para distinguir diversidad meteorológica de simple volumen de proveedores.
- La probabilidad y precipitación previstas no se alteran por este límite: se corrige únicamente cuánta confianza comunica RainETA sobre la hora prevista.
- La caché de previsión queda ligada a la versión de RainETA: tras actualizar el motor, la app descarta cálculos de una versión anterior en vez de reutilizarlos hasta 20 min con una interfaz ya actualizada.

## Frescura y desacuerdo de radares v0.17.4
- El radar europeo OPERA deja de contar como fuente sana si el composite supera **30 min**; para confirmar lluvia superficial se mantiene un límite más estricto de **20 min**.
- El panel de Fuentes muestra la **edad real** de RainViewer y OPERA y marca explícitamente cuándo un radar está desactualizado y queda excluido de ETA/consenso.
- Cuando RainViewer y OPERA difieren más de 30 min en la llegada, RainETA mantiene la fuente mejor respaldada pero **penaliza la confianza** y ensancha la incertidumbre proporcionalmente al desacuerdo.
- AEMET OpenData sigue evaluado como siguiente fuente española: ofrece radar regional y composición nacional, pero requiere API key y no se expondrá una clave privada en la PWA.

## Reproducción y realismo radar v0.17.3
- El histórico observado deja de pasar a toda velocidad: el botón ▶ recorre los **barridos reales** con una pausa visible (~600 ms por frame) y conserva la velocidad fluida de 1 min por paso en el futuro.
- RainViewer deja de contar como fuente sana o autoritativa si el último barrido tiene más de **20 min**; en ese caso la ETA depende de OPERA/modelos y la imagen queda solo como referencia observada.
- La extrapolación visual futura deja de trasladar rígidamente el mismo bloque durante 4 h: dentro del horizonte fiable combina movimiento global y flujo local; fuera de él **desacelera progresivamente**, aumenta ligeramente la dispersión visual y reduce más la opacidad.
- El movimiento fuera del horizonte fiable nunca gana autoridad meteorológica: modelos/consenso siguen mandando en la ETA y en la decisión.

## HASTA LLUVIA continuo y radar visual 4 h v0.17.2
- Recupera **▶ HASTA LLUVIA** como botón principal también cuando la ETA procede de modelos/consenso.
- Si hay una ETA dentro de las próximas **4 horas**, la animación avanza hasta esa hora aunque la ETA proceda de modelos/consenso. Si no existe movimiento radar suficientemente fiable, conserva el último radar atenuado como referencia visual y no lo presenta como predicción física.
- La animación futura pasa de saltos de 5 minutos a **pasos de 1 minuto** y actualiza las coordenadas de la misma capa radar, reduciendo parpadeos y dando una evolución visual más continua.
- El slider del radar se amplía hasta **+240 min**. La banda corta permanece en 0–180 min.
- Fuera del horizonte fiable la imagen se atenúa progresivamente; la ETA deja claro que la hora la decide el consenso/modelos y que la extrapolación radar es solo orientativa.
- El botón manual ▶ también usa pasos de 1 minuto en el futuro (los fotogramas observados históricos siguen saltando de barrido en barrido).

## Continuidad visual AHORA → proyección v0.17.1
- Corrige el salto visual entre el radar real de `AHORA` y `+5 min`.
- El radar observado ya se mostraba con suavizado de RainViewer (`1_1`), mientras que la proyección visible reutilizaba por error la imagen cruda (`0_0`) destinada al análisis de píxeles.
- A partir de esta versión, el **cálculo interno** continúa usando la imagen cruda, pero el **mapa proyectado** usa la misma representación suavizada que el radar observado.
- Por tanto, `AHORA` y `+5 min` conservan la misma geometría visual de precipitación y solo cambia su desplazamiento; no debe parecer que los ecos desaparecen de golpe al cruzar `AHORA`.

## Interfaz por fuente y radar extendido v0.17.0
- La banda corta pasa de **0–120 min a 0–180 min** en pasos de 5 minutos.
- El fondo/encabezado de la banda diferencia visualmente **RADAR**, **MEZCLA** y **MODELOS**, de acuerdo con el peso real del nowcast.
- La extrapolación visual del mapa radar se amplía hasta **+180 min**. Más allá del horizonte fiable se atenúa aún más; no se utiliza como evidencia canónica.
- El slider del radar marca explícitamente **fiable hasta ~HH:MM**.
- La tarjeta principal muestra una línea compacta `Basado en radar / Radar + modelos / Basado principalmente en modelos` y confianza **ALTA / MEDIA / BAJA**, manteniendo el porcentaje en pequeño.
- Se añade **Próximo fenómeno importante** solo cuando en las próximas 24 h hay lluvia fuerte o tormenta.
- Los episodios lejanos aparecen plegados en una sola línea; se abren para ver evolución y detalle 15/30 min. Los episodios activos o dentro de 3 h se abren automáticamente.
- `Mis lugares` se reduce a tres datos rápidos: **Ahora**, **Próxima lluvia** y **Hasta cuándo**.
- AEMET sigue preparado como siguiente fuente española, pero no se activa sin `AEMET_API_KEY`; no se añade una función Serverless nueva.

## Nowcast v2: flujo local + relevo a modelos v0.16.0
- RainViewer deja de proyectarse con un único vector rígido para la decisión de lluvia. El cliente estima **movimiento local** en una malla de zonas y sigue el eco que puede alcanzar el punto.
- Se mide la **evolución/deformación** entre los dos últimos barridos. Si la precipitación crece, se rompe o cambia mucho de forma, baja la confianza y se acorta el horizonte radar.
- El horizonte radar útil pasa a ser dinámico (aprox. 20–90 min). Fuera de él, la decisión deja de usar el radar como fuente dominante y da el relevo a consenso/modelos.
- OPERA usa el mismo principio de flujo local y fiabilidad de evolución en el backend existente `/api/rain-opera`; no se añade ninguna Serverless Function.
- El 0–120 min mezcla radar/OPERA con modelos de forma progresiva: radar domina al principio y su peso llega a cero cuando termina su horizonte fiable.
- En España el `minutely_15` de Open-Meteo se trata como **interpolación horaria**, no como una predicción nativa de 15 min: ya no puede desplazar inicio/fin de episodios ni prolongar artificialmente el detalle fino.
- La tarjeta corta muestra `Radar útil ~N min` y el relevo posterior a modelos. El mapa atenúa las proyecciones posteriores al horizonte fiable y las marca como referencia visual.
- `HASTA LLUVIA` solo anima hasta una ETA respaldada por radar dentro de ese horizonte. Si la ETA procede del relevo a modelos, se indica `ETA POR MODELOS` y no se anima un mapa radar engañoso.
- AEMET queda como fuente candidata prioritaria para España, pero su integración programática requiere una API Key de AEMET OpenData; no hay una clave configurada actualmente en el proyecto.

## Hotfix de recursión de feedback v0.15.8
- Corrige `Maximum call stack size exceeded` cuando existía un `No llueve` reciente pero ya no debía gobernar el estado actual.
- Las correcciones de episodio por feedback solo se calculan mientras ese feedback sigue vigente como verdad actual.
- `canonicalEpisodeSnapshot()` deja de reconstruir episodios a través de la línea canónica; usa directamente los eventos de modelo para romper cualquier ciclo `decisión → corrección → episodio → decisión`.
- El hotfix no cambia la previsión de 7 días ni las reglas de lluvia fuerte.

## Vista compacta y previsión 7 días v0.15.7
- Se eliminan de la vista principal las explicaciones repetidas de `pausa dentro del episodio`, el texto auxiliar de Episodios y las métricas largas de aprendizaje.
- La autoevaluación y el comparador de fuentes siguen funcionando, pero se mueven al desplegable **Fuentes, modelos y diagnóstico**.
- Nuevo desplegable **Previsión 7 días**. Cerrado muestra cuántos de los próximos 7 días tienen lluvia prevista.
- Al abrirlo aparecen los siguientes siete días completos (desde mañana) con el nombre del día y un **SÍ / NO**.
- Cuando es `SÍ`, se muestran los rangos horarios con señal de lluvia, probabilidad máxima del tramo y precipitación orientativa; también total diario y pico horario.
- La previsión semanal usa una petición ligera de Open-Meteo a 8 días y no añade funciones Serverless ni carga los 15 modelos/ensembles más allá de las 72 h.
- Criterio semanal: se marca un tramo cuando hay precipitación prevista y señal suficiente de probabilidad; el horizonte de 4–7 días es orientativo y menos preciso que el nowcast/72 h.

## Verdad en superficie y tramos fuertes exactos v0.15.6
- `Llueve ahora` deja de afirmarse por un único eco moderado o por los modelos. Se confirma con **dos radares recientes concordantes**, una señal radar local claramente intensa o feedback del usuario.
- Si solo un radar detecta precipitación moderada sobre el punto, RainETA muestra **Lluvia no confirmada**: el eco puede estar en altura o no estar llegando al suelo.
- Los modelos siguen influyendo en riesgo y episodios futuros, pero **no deciden el estado actual**.
- El primer bloque de 5 min no se pinta como lluvia si la precipitación superficial no está confirmada.
- Un episodio largo ya no se colorea entero como fuerte por contener un único pico. La cabecera muestra `Tramos de lluvia fuerte` con las **horas exactas** y el pico de cada intervalo.
- Solo los tramos que alcanzan **≥7,5 mm/h** reciben borde/fondo rojo completos; tormentas o chubascos fuertes conservan esa alerta roja.

## Alerta visual de lluvia fuerte v0.15.5
- RainETA considera **lluvia fuerte** a partir de **7,5 mm/h**.
- Si cualquier tramo de un episodio alcanza ese nivel, el episodio completo se marca con **línea roja superior**, borde rojo y etiqueta `LLUVIA FUERTE`.
- Los tramos concretos de lluvia fuerte usan rojo también en el detalle y en la línea inferior del gráfico temporal.
- Un chubasco que alcance 7,5 mm/h o más se muestra como **Chubasco fuerte** y recibe la misma señal roja.
- La leyenda muestra explícitamente `Fuerte ≥7,5 mm/h`.

## Resumen limpio y sincronización canónica v0.15.4
- En estado seco se elimina el párrafo largo redundante de la cabecera: queda un único resumen compacto de fuentes y decisión.
- `OPERA` se presenta al usuario como **Radar europeo**; el nombre técnico EUMETNET OPERA permanece en Fuentes y modelos.
- La ETA canónica deja de moverse con el historial guardado en cada navegador. Los barridos anteriores solo sirven como diagnóstico de variación, no para cambiar la hora principal.
- Cuando RainViewer y el radar europeo discrepan mucho, la fuente se elige por la confianza del dato actual, no por un marcador aprendido localmente.
- El aprendizaje local sigue registrándose y mostrándose, pero no modifica por sí solo la previsión canónica hasta disponer de sincronización entre dispositivos.
- Radar, radar europeo y guía de 15 min se refrescan juntos cada 5 min, alineados a los mismos límites del reloj. Al volver a una pestaña se actualizan si llevan más de 90 s sin refrescar.
- Si se abre la app con una caché de previsión lenta, los datos vivos se actualizan antes de renderizar cuando esa caché tiene más de 90 s.
- Para reducir diferencias de GPS entre dispositivos, las fuentes meteorológicas usan un punto de cálculo común redondeado a ~0,001°; el mapa conserva la ubicación real.

## Coherencia entre dispositivos y detalle adaptativo v0.15.3
- El feedback `No llueve` solo modifica visualmente el estado durante unos minutos; después la decisión vuelve al cálculo canónico compartido por radar/OPERA/modelos, reduciendo divergencias entre móvil y web.
- Al registrar feedback se guarda el **episodio canónico visible** de ese instante, no una ventana modelo amplia. Los registros antiguos anormalmente largos se ignoran para evitar casos como `Previsión anterior 06:00`.
- El detalle de episodios pasa a **15 min mientras exista información a esa resolución** (Radar / nowcast o Modelo 15 min). Desde el primer punto donde deja de existir, continúa automáticamente en **tramos de 30 min**, sin repetir artificialmente el mismo dato horario cada 15 min.
- Se renombra la guía temporal como **Modelo 15 min** y el radar proyectado como **Radar / nowcast** para hacer explícita la fuente.
- Cada tramo incorpora una línea de color por tipo de tiempo: llovizna, lluvia débil, chubascos, lluvia moderada, lluvia fuerte, tormenta, nieve, nublado, niebla o seco.
- El gráfico largo conserva relleno=probabilidad y altura=intensidad, y añade una línea inferior que identifica el tipo de tiempo.

## Pausas y fin anticipado de episodios v0.15.2
- `No llueve` corrige **el instante actual**, no elimina automáticamente todo el episodio.
- Si el nowcast detecta otro pulso dentro del episodio, RainETA muestra **pausa seca** y una posible reanudación, conservando el fin previsto anterior como contexto.
- Si el seco persiste y lo respaldan radar/OPERA o varias observaciones del usuario, el tramo se **cierra antes de lo previsto** y se recalculan cabecera, 0–120 min y barras canónicas.
- Cada final anticipado guarda el fin previsto, el fin observado, la fuente y los minutos de exceso. Tras al menos 5 correcciones, se aplica un ajuste local suave y limitado (máx. 15 min) a finales basados en modelos; el nowcast reciente sigue teniendo prioridad.
- El botón `HASTA LLUVIA` usa también esta decisión corregida para no seguir apuntando a un episodio ya cerrado.

## Episodios a 30 minutos v0.15.1
- El detalle de `Episodios previstos` se muestra en bloques de **30 min** en vez de horas completas.
- En las primeras 2 h usa el nowcast canónico RainViewer + OPERA; después aprovecha la guía de 15 min cuando está disponible y conserva el consenso horario como base.
- Cada fila indica si está afinada con `nowcast` o `guía 15 min`, evitando presentar interpolación como observación.

## OPERA espacial, aprendizaje y huecos secos v0.15
- OPERA NIMBUS RATE aporta un **segundo nowcast espacial independiente**: se comparan varios compuestos de 5 min, se estima movimiento del eco y se proyecta una ETA 0–120 min sin crear una función Serverless adicional.
- RainViewer y OPERA se cruzan: si sus ETAs son próximas, RainETA calcula una ETA fusionada; si discrepan mucho, mantiene la discrepancia visible y prioriza la fuente más fiable.
- Se inicia un **marcador local de acierto por fuente y horizonte** para RainViewer, OPERA y modelos en +15/+30/+60/+90/+120 min. Solo influye de forma suave cuando ya hay suficientes verificaciones independientes.
- `Mis lugares` añade la **mejor ventana seca de las próximas 24 h**, además de próxima lluvia, duración y tiempo seco actual.
- El radar incorpora **▶ HASTA LLUVIA**: anima desde la posición actual y se detiene automáticamente en la ETA canónica de llegada al punto; se desactiva si la ETA queda fuera de +120 min o la proyección radar no es fiable.
- La tarjeta 0–120 min usa también la proyección espacial de OPERA para intensidad/probabilidad, conservando el RainDecision canónico como única decisión visible.

## Motor canónico y Mis lugares v0.14
- Se crea un **RainDecision canónico** con estado actual, ventana seca, próxima lluvia, duración, confianza y riesgo de modelos. La cabecera, tarjeta 0–120 min, contador, gráfico largo y episodios se alinean sobre la misma decisión.
- Las **ventanas secas** pasan a primer plano: si el radar fiable está seco, la cabecera principal muestra `Seco hasta HH:MM`, con tiempo seco y confianza, en vez de presentar el riesgo posterior como lluvia inmediata.
- `Episodios previstos` muestra siempre la ventana seca radar inicial como bloque prioritario cuando existe.
- `Mis lugares` amplía la vista rápida a 24 h: muestra próxima lluvia, hora estimada, duración aproximada y cuánto tiempo seco queda; si ya llueve, muestra fin aproximado y siguiente pulso cuando lo hay.
- Se inicia un historial local de decisiones de 7 días por ubicación (`raineta.decisionHistory.*`) para poder contrastar predicción vs realidad y alimentar calibración posterior.

## Decisión práctica v0.13
- El radar muestra **siempre una hora absoluta** arriba a la derecha, también en la proyección; los `+15 min`, `+50 min`, etc. quedan solo como explicación secundaria.
- La ubicación GPS actual puede guardarse como **lugar permanente**: se conserva como una instantánea fija aunque más adelante cambie la ubicación GPS actual.
- La cabecera muestra una decisión transparente tipo: `RainViewer: seco · OPERA: 0,0 mm/h · modelos: riesgo 63 % → RainETA: seco hasta 15:20`.
- El contador en vivo respeta la ventana seca radar y ya no vuelve a `>2 h` mientras haya una ventana seca fiable activa.

## Coherencia radar-modelos v0.12
- Cuando el nowcast radar es suficientemente fiable y no proyecta precipitación sobre el punto, RainETA crea una **ventana seca radar** de hasta 120 min.
- Esa ventana tiene prioridad sobre señales horarias de modelos a corto plazo: un episodio multimodelo que empezaba “ya” se retrasa hasta el final de la ventana seca o se descarta si termina dentro de ella.
- La tarjeta de corto plazo y el resumen superior explican el desacuerdo: `radar seco hasta HH:MM · modelos mantienen riesgo después`.
- El resumen añade, cuando existe, la duración seca posterior al episodio y la hora del siguiente pulso.
- Episodios previstos muestra también una ventana seca inicial respaldada por radar.
- El radar incorpora **CENTRAR** para devolver el mapa al punto seleccionado sin cambiar el instante temporal; `AHORA` sigue devolviendo el radar al último barrido.

## Radar
RainViewer aporta los últimos barridos. RainETA descarga una imagen centrada en la ubicación, genera una máscara de precipitación en el dispositivo, calcula traslación entre barridos y proyecta el píxel de la ubicación cada 5 minutos hasta 120 minutos.

El radar se refresca cada 5 minutos mientras la PWA está visible; los modelos se cachean durante 20 minutos para no malgastar ancho de banda ni CPU.

## Arquitectura y coste
RainETA reutiliza una función serverless ya existente para el backend cacheado de OPERA y mantiene el resto del nowcasting en el dispositivo. Así evita aumentar el número total de funciones del proyecto y reduce llamadas repetidas al proveedor europeo.

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
