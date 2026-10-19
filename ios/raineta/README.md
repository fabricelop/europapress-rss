# RainETA para iPhone — v0.11.0

## v0.11.0 — Precipitación primero y Actividad en Vivo mejorada

- **Lluvia/nieve son las prioridades** de la app. Pantalla principal: estado y cuenta atrás, Pulso local 0–120 min, próximo período de 3 horas, radar observado/nowcast y después semana/modelos. Temperatura queda como información secundaria.
- Open-Meteo proporciona `weather_code` y `snowfall` actuales, además de `snowfall` horario en centímetros. El tipo de precipitación se deriva **del modelo**, NO de colores del radar; un eco radar solo ayuda a confirmar presencia/ausencia de precipitación, no si es nieve.
- El Pulso de precipitación mantiene barras por minuto *visuales* de equivalente líquido en mm/h, etiqueta nieve cuando corresponde según modelo y no inventa resolución física minuto a minuto.
- **Actividad en Vivo (pantalla bloqueada y Dynamic Island):** estado de precipitación, icono de lluvia/nieve, cuenta atrás cuando hay cambio, barra compacta de los próximos 60 minutos, procedencia del dato (radar local o modelo) y hora de actualización. La temperatura aparece pequeña y opcional. Sin ETA se presenta estado seco o precipitación en curso, no un contador ficticio.
- La extensión actualiza `staleDate` tras ~12 minutos con radar validado o ~25 minutos con modelos. Los datos sin actualizar aparecen como antiguos. El contador puede seguir avanzando con el reloj de iOS, pero **la app no recibe datos meteorológicos nuevos cuando iOS la suspende**.
- Estado de Actividad en Vivo compatible con datos antiguos mediante propiedades opcionales: fase, procedencia, confianza, hora observada, temperatura y doce barras de intensidad. Los tramos sin dato son **desconocidos**, no secos.
- **No se añade un widget independiente.** El paquete sigue siendo una IPA sin firmar para Sideloadly; la disponibilidad efectiva de Actividades en Vivo depende de la firma/permisos y de iOS. No se promete que una extensión funcione en cualquier instalación.
- Pruebas para lluvia/nieve, previsión futura, barras y compatibilidad de estado; compilación y tests iOS se verifican en GitHub. **Sin cambios en la PWA ni infraestructura de servidores.**

# RainETA para iPhone — v0.10.1

## v0.10.1 — Reparación del radar local: Madrid se veía seco pero el modelo decía lluvia

- **Causa corregida:** el código de la versión 0.10.0 construía las URL de las teselas de radar con latitud/longitud en los campos Web Mercator x/y, además de consultar una ruta de cobertura inexistente. La capa visible del mapa usaba x/y correctos, pero el motor de predicción local no: por eso podía caer al modelo meteorológico aunque el radar mostrase la localidad seca.
- **Mismo dato que el mapa:** se proyecta la coordenada GPS o seleccionada a x/y enteros en z7, se descarga la misma paleta y el mismo fotograma del radar visible, y se comprueba el **píxel real de la ubicación** y sus vecinos. Para Madrid (40.4168, −3.7038), x=62, y=48, píxel local=(174,67): **nunca el centro de la tesela ni la latitud en la URL**.
- Una tesela PNG descargada correctamente y transparente puede representar ausencia de eco. Si hay errores de red, falta el fotograma o la imagen no se puede decodificar, la lectura queda **no disponible**, no se interpreta como seco.
- Se acepta **radar observado de RainViewer** para la situación actual cuando LibreWXR no proporcione nowcast. Sin futuro real del proveedor, la observación solo prevalece unos 10 min y pierde peso hasta los 20 min; después vuelven las previsiones por modelos.
- El estado **ahora** se comprueba con el último fotograma observado, no con una predicción futura que todavía no es observación. El pronóstico del resto de los 60 min se apoya en los fotogramas nowcast disponibles y el Pulso, la gráfica de tres horas y la cuenta atrás comparten esa decisión.
- La pantalla distingue **«Radar: sin eco local»** y **«Modelo prevé lluvia · no confirmada»**. No se presenta como medición la intensidad modelada, ni se garantiza que un radar despejado descarte llovizna muy débil bajo el umbral de detección.
- Reparación de transición opuesta: si el modelo dice «llueve» y el radar indica «seco», ya no se reutiliza por error la hora **de final de lluvia** como cuenta atrás **de comienzo de lluvia**.
- Pruebas de URL x/y y píxel real de Madrid, PNG transparente, fuente alternativa con radar observado sin nowcast, diferencia entre observado seco y futuro previsto mojado y transición contradictoria. Diagnóstico de tesela real en GitHub Actions (advertencia no bloqueante si el proveedor está temporalmente inaccesible).
- La precisión real continúa dependiendo de la cobertura, frecuencia y frescura de los radares. No se garantiza lluvia al minuto exacto. Sin servidores propios, Vercel ni Cloudflare.

# RainETA para iPhone — v0.10.0

## v0.10.0 — Radar local prioritario para el pronóstico inmediato

- Un único cálculo alimenta **contador, Actividad en Vivo, Pulso de lluvia y próximas 3 horas**. Evita contradicciones entre la primera tarjeta y los gráficos.
- Nuevo muestreo a las **coordenadas del lugar seleccionado** de mosaicos de radar observado y nowcast de LibreWXR. Se comprueba frescura del último barrido, cobertura por el proveedor y presencia de suficientes fotogramas. Un error HTTP, falta de cobertura o datos antiguos no se consideran «seco».
- Cuando el radar local es válido, sus ecos y fotogramas pronosticados tienen **prioridad de 0 a 60 minutos**. Si está seco en radar pero el modelo prevé lluvia ahora, no se anuncia lluvia inmediata sin soporte del radar.
- Entre 60 y 90 minutos se atenúa la señal del último nowcast como **tendencia de baja confianza**; a partir de 90 minutos se vuelve a la previsión de 15 minutos y al consenso horario de modelos. El pronóstico llega hasta 120 minutos en Pulso y hasta 180 minutos en la gráfica de tres horas; **no se afirma que exista radar fiable de 120 minutos**.
- El minuto es la **resolución de la visualización**, interpolada o asignada al intervalo real del proveedor (10 min radar, 15 min o 60 min modelos); NO son mediciones independientes por minuto. El radar de reflectividad sin calibración no puede aportar mm/h físicos fiables: se usa para decidir presencia/ausencia y se muestran intensidades **indicativas** procedentes de modelos cuando hay eco.
- La localización y vigencia del radar son visibles en la primera tarjeta; si no hay cobertura, RainETA vuelve al pronóstico de modelos, claramente etiquetado.
- Los totales de lluvia de toda la semana siguen siendo de los modelos (no se alteran con una falsa cuantificación del radar). Hoy y el periodo 0–180 min se destacan como perspectivas distintas cuando hay radar válido.
- Pruebas: conflicto radar seco/modelo mojado, modelo seco/radar mojado, cambio futuro, atenuación 60–90 minutos, caída de cobertura o frescura, selección de fotograma local. Las pruebas de CI no demuestran precisión física en un lugar real.
- Sin coste adicional ni Vercel/Cloudflare, sujeto a que LibreWXR siga disponible. Crédito LibreWXR conforme a condiciones de la fuente.

# RainETA para iPhone — v0.9.2

## v0.9.2 — Pulso minuteado legible y ahora radar futuro coherente

- **Pulso 30/60/120 min:** una barra por minuto, colores por intensidad, seco claramente gris, desplazamiento horizontal sin amontonar 120 barras en el ancho del iPhone y pulsación para consultar minuto e intensidad.
- La curva de consenso que aplanaba la alternancia seco/lluvia deja de prevalecer sobre el dato de 15 minutos: las barras principales usan el **acumulado del intervalo de 15 minutos anterior** (mm/h promedio), sin difuminarlo hacia intervalos donde el proveedor no predijo lluvia. Solo si falta ese dato se usa la mediana horaria de los modelos. Esto mantiene la duración e inicio visual de los episodios, pero **no convierte un dato de 15 minutos en un cálculo meteorológico de un minuto**.
- Comparación opcional: filas individuales ECMWF, ICON, GFS, ARPEGE y UKMO; al pulsar cada fila se despliegan **sus propias barras de un minuto**. Como la predicción de esos centros es horaria, las barras de una misma hora repiten la intensidad media de dicha hora, sin simular resolución temporal adicional.
- La cabecera indica seco/lluvia actuales y un posible comienzo o final, solo si al menos 5 minutos consecutivos de la serie respaldan ese cambio. Se conservan el contador grande y Live Activity.
- **Radar y predicción espacial:** nueva fuente coherente **LibreWXR** (EUMETNET OPERA + predicción experimental por flujo óptico y modelos). Ofrece históricos y seis imágenes **reales del proveedor** de +10 a +60 minutos. Ya no se mezclan los campos ICON-EU horarios enormes con el radar a +5 min. Mismo mapa, colores, teselas y servicio en ambos lados de AHORA.
- Si LibreWXR está caído o sus datos caducan, se muestra exclusivamente el radar **observado** de RainViewer: nunca se fabrican fotogramas futuros. Se ha retirado la precarga costosa de mapas WMS de DWD en el mapa inicial, manteniendo MapKit y zoom.
- Las predicciones experimentales de LibreWXR son fotogramas cada diez minutos, **no radar medido futuro**. Las **dos horas** completas corresponden al Pulso local: la animación geográfica solo llega a **60 minutos** mientras el proveedor no publique un nowcast espacial fiable mayor.
- Sin Vercel, Cloudflare, despliegue ni cuota adicional. LibreWXR publica la API sin claves y datos bajo CC BY 4.0 (crédito visible en mapa), sujeto a su disponibilidad.
- La exactitud de las barras y el comportamiento real del radar se deben verificar en iPhone durante episodios reales de precipitación; los tests comprueban lógica, construcción y fuentes pero no calidad meteorológica observacional.

## v0.9.1 — Correcciones de legibilidad y continuidad del radar

- **Pulso:** se sustituye el gráfico superpuesto Swift Charts de alta densidad por dibujo Canvas de tamaño limitado. La curva central, la franja de discrepancia y la serie automática quedan dentro de los límites del gráfico, sin cubrir texto ni controles.
- **Modelos del Pulso:** despliegue en filas legibles con nombre, precipitación horaria actual, máximo y evolución temporal; mejor comparación que superponer cinco líneas sin explicación suficiente.
- **Comparación diaria:** selector horizontal de Hoy/Mañana/+Nd y una fila por centro con cantidad en mm y barra comparativa, evitando siete columnas minúsculas en el iPhone.
- **Mapa futuro:** precarga central de ICON-EU al abrir el mapa, reduce la espera de hasta 36 teselas a un máximo de nueve centrales por avance y aumenta caché WMS.
- **Reproducción:** espera a que un fotograma esté realmente preparado y visible antes de avanzar; no indica como dibujado un nuevo instante si el servidor WMS todavía está calculándolo.
- **Transición visual radar→ICON-EU:** se conserva el radar observado y se superpone gradualmente el modelo en los primeros 30 minutos. La mezcla es solamente visual y se etiqueta como tal: **no es radar futuro ni una evolución física calculada**. A los +30 minutos el mapa es completamente ICON-EU.
- Se mantiene el **contador de lluvia** del inicio y la Actividad en Vivo, y también el funcionamiento de las previsiones y ubicaciones.
- Pruebas nuevas de cotas de precarga y transición, además de la suite de regresión existente.
- Pendiente validar en iPhone real la suavidad y rapidez del WMS en redes lentas; sigue dependiendo de la latencia del proveedor DWD.

## v0.9.0 — Pulso de lluvia comparado entre centros meteorológicos

- **Cuenta atrás principal conservada**, junto con la Actividad en Vivo: prioriza el movimiento del radar solo con evidencia fresca y suficiente confianza; mantiene la previsión principal si falla el radar o los modelos.
- Pulso de lluvia 30/60/120 minutos: curva central = **mediana de las intensidades de los modelos disponibles**; banda sombreada = rango mínimo–máximo; curva verde discontinua = **Pulso automático original de 15 minutos**. Si hay menos de dos modelos, permanece únicamente la serie automática de 15 minutos.
- Botón **Ver modelos individuales**: ECMWF IFS, DWD ICON, NOAA GFS, Météo-France (principalmente ARPEGE en España) y UK Met Office. Cada trazo muestra las acumulaciones de precipitación correspondientes a la **hora precedente**, expresadas como intensidad horaria media. Un minuto en la pantalla no significa que el modelo haya calculado una nueva previsión en ese minuto.
- Próximas 3 horas: indicador de acuerdo/desacuerdo durante las primeras dos horas. Comparador diario: cinco centros, con límite de cuatro días para Météo-France.
- Series calculadas sobre la localización seleccionada. La caché es local y limitada; los fallos parciales no se contabilizan como pronósticos secos y no bloquean la cuenta atrás.
- El radar utilizado para estimar cuándo entra o sale la lluvia **no se representa como mm/h físico** en el Pulso: la señal de reflectividad/eco no proporciona por sí sola una tasa de precipitación calibrada. No se finge la precisión de un minuto.
- **AEMET HARMONIE-AROME no se integra aún**: los productos públicos no ofrecen actualmente en este código una ruta simple y validada de consulta puntual/minutal sin configuración adicional. No se le atribuyen datos no descargados.
- Créditos y licencias: ECMWF, Deutscher Wetterdienst, NOAA/NCEP, Météo-France, UK Met Office. La fuente UKMO se publica a través de Open-Meteo bajo condiciones **CC BY-SA 4.0** que deben respetarse al redistribuir productos derivados; ver https://open-meteo.com/en/docs/ukmo-api. Se mantiene explícita la identificación de fuentes.
- Añadidas pruebas de mediana, dispersión, faltantes, cadencia horaria y conversión UTC. Pendiente la validación real de precisión en iPhone ante lluvia local.

## v0.8.1 — Cuenta atrás mantenida y estimación de lluvia 0–120 minutos

- Se **conserva el contador principal** de llegada/fin de la lluvia, con actualización local cada segundo y soporte para la Actividad en Vivo.
- Si hay radar RainViewer reciente, dos barridos válidos y suficiente coherencia del movimiento, se estima un posible cambio local usando proyección de ecos a un minuto. No son observaciones nuevas ni una previsión independiente de precisión de un minuto.
- Se contrasta la hora aproximada con precipitación **horaria** de ECMWF, ICON y GFS. Los modelos no determinan el minuto exacto: sus acuerdos refuerzan la confianza o amplían la advertencia de incertidumbre.
- Bajo el contador se muestra el método, el nivel de confianza y, cuando el cambio procede del radar, una **ventana horaria orientativa** para llegada o final.
- Si el radar es antiguo (>12 min al calcular o >15 min durante el uso), las imágenes son incompletas, el movimiento no alcanza el umbral de confianza, no hay cambio sostenido o discrepan claramente los modelos con radar débil, se mantiene la cuenta atrás tradicional por Open-Meteo.
- Cálculo asíncrono para no bloquear la pantalla; caché de barridos y modelos, protección frente a resultados antiguos al cambiar de lugar. Sin servidor propio, Vercel ni Cloudflare.
- Pruebas de entrada/salida, franjas, caducidad, discrepancia y atribución horaria. La precisión física todavía requiere validación en el iPhone ante lluvia real.



App **nativa SwiftUI / MapKit / ActivityKit** para instalación mediante Impactor en iPhone. Carpeta aislada: `ios/raineta/`. No se modifica la PWA existente y **no utiliza Vercel ni Cloudflare**.

## v0.8.0 — Pantalla compacta, histórico real y navegación fina

- Inicio: contador, pulso, próximas 3 horas, semana, radar al final y comparador de modelos contraído debajo. Se eliminan los textos técnicos repetidos.
- Radar: imágenes observadas de RainViewer dentro de las últimas 2 horas **solo cuando el proveedor las entrega**; barra con marca de AHORA, flechas de cinco minutos en futuro, botones para volver a ahora y centrar en la localidad; los barridos pasados avanzan exclusivamente de una observación real a la siguiente.
- MapKit: mantiene el último campo completo hasta cargar las teselas visibles del siguiente; precarga alrededor del viewport; cancela peticiones obsoletas al deslizar rápido o cambiar de hora; evita que un resultado tardío sustituya una selección reciente.
- Detalles diarios: los acumulados horarios de Open-Meteo corresponden a la hora **precedente**, por lo que el sello 07:00 representa 06:00–07:00. El de 00:00 se atribuye al día anterior, incluyendo los episodios que terminan a medianoche.
- La probabilidad y la cantidad son variables distintas: cuando los horarios que muestran lluvia y los máximos de probabilidad difieren significativamente, se informa en el detalle diario.
- Semana: temperaturas mínimas y máximas en una sola línea; filas pulsables para ver cada día y sin duplicación de fichas en Inicio.
- Mis lugares: el título Comparador en directo ahora abre una vista interactiva de localidades; mantiene la ordenación manual guardada y la posibilidad de seleccionar un lugar.
- Modelos ECMWF/ICON/GFS: panel al final, contraído por defecto, consultas bajo demanda y aviso cuando los modelos divergen.
- La extrapolación de 5 minutos en futuro inmediato **no equivale a predicciones independientes**: se interpola visualmente entre dos campos ICON-EU horarios. No se oculta esa distinción en los ajustes.
- La historia de radar no se simula ni completa artificialmente.

## v0.5.0 — Sustitución completa de la capa futura anterior

- **Retirado en pantalla el mapa de 9×9 puntos de Open-Meteo**, que mostraba círculos irreales y bordes rectangulares; también sigue deshabilitada la translación/difuminado del radar.
- **Nuevo origen oficial:** WMS de Deutscher Wetterdienst (DWD), modelo ICON-EU, capa `dwd:Icon-eu_reg00625_fd_sl_TOTPREC01H` de precipitación acumulada en la hora anterior.
- **Mapas meteorológicos integrales:** MapKit solicita al servidor mapas reales en proyección EPSG:3857 de la región solicitada, en vez de convertir pronósticos puntuales en manchas.
- **Zoom:** se han verificado llamadas WMS con PNG válido a niveles 6, 9 y 12. El servidor puede atender consultas a distintos niveles pero **no hay más detalle meteorológico real que el del modelo (~6 km)**.
- **Secuencia futura por horas reales:** la fuente es horaria. RainETA presenta +1h, +2h, +3h, +4h; no finge disponer de campos meteorológicos independientes cada cinco minutos.
- **Transición protegida:** al pasar de radar a modelo, no se borra la observación hasta recibir una tesela PNG válida de la previsión; si falla el WMS, se conserva el radar y se informa.
- **Cobertura inicial:** Europa. Fuera de esa región no se muestra una previsión espacial que no existe.
- **Fuente y atribución:** DWD / ICON-EU enlazado en la app; el radar histórico sigue siendo RainViewer. Live Activities y los lugares guardados no cambian.
- **Validación:** pruebas de proveedor para Europa e Iberia, prueba de entrega a zoom 6, 9 y 12, además de tests unitarios iOS de construcción geográfica WMS, tiempo y región. Se guardan imágenes de referencia en GitHub Actions.

**Limitaciones conocidas:** este modelo todavía no se fusiona con el radar de los últimos minutos y no es una predicción hiperlocal inmediata. La discontinuidad entre imagen radar y previsión del modelo es una diferencia real entre fuentes, no algo que se deba ocultar con opacidad artificial. Para España, los siguientes candidatos a integrar son los campos HARMONIE-AROME de AEMET; para los primeros minutos, evolución óptica calibrada con varios barridos reales y validación retrospectiva.

## v0.4.0 — RainETA Future Rain Model Map

- Future rain is no longer inferred by translating or fading a single RainViewer image. A 9×9 grid of forecast precipitation is fetched for the visible MapKit region using Open-Meteo's **multiple coordinates** Forecast API (three batches of 27 points).
- Each 15-minute model field is geographically positioned in global Web Mercator. Per-map-tile rendering uses spatial bilinear interpolation and interpolates adjacent **forecast model timestamps**, so future rain may emerge, intensify, move or dissipate. All map zoom levels (0–20) use the same georeferencing. On panning/zooming away from the currently covered area, the model grid is refreshed.
- The latest observed RainViewer frame remains visible when entering the future; if valid model fields exist, the observed radar transitions to the *separately computed* model field over about 30 minutes. If model data is unavailable, observed radar is maintained rather than displaying a fabricated empty future.
- Separate source labels: **RADAR OBSERVADO** versus **PREVISIÓN MODELO · NO RADAR**. The forecast model does not claim radar resolution.
- Animated historical/future timeline in steps of five minutes through +4 hours; interactive playback.
- Automated GitHub Actions gates: public provider 3-point schema/timestamp smoke test and iOS Simulator XCTest verifying model changes over time, near-future non-empty precipitation and visible tiles at zoom 7/12/16.
- iOS Live Activity displays the selected saved location, or GPS municipality when available, and keeps a stale-data warning.
- The previous saved-places tab remains separate from the main radar screen.

### Model / resolution limitations

Open-Meteo may interpolate hourly precipitation into 15-minute steps outside areas with genuinely 15-minute forecast models; these are not independent 15-minute weather forecasts. Geographical resolution is limited to 9×9 sampled model points over the current map view. Zooming in reveals that model interpolation more clearly but does not create new forecast physics; RainETA refreshes a local field when necessary.

**Not yet implemented:** operational high-resolution OPERA composite blending, optical-flow validation of multiple radar sweeps, assimilation into nowcast, precipitation uncertainty cones, archived forecast-vs-observation skill measurements. Those are distinct from the current operational *model forecast raster*. No promise of TV-graphics-grade accuracy or of better-than-official models.

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

La acción compila sin firma en macOS el bundle `RainETA.app` con `RainETALive.appex` y genera `RainETA-0.8.1-unsigned.ipa`. La IPA debe firmarse en Impactor; usar Apple ID y mantener la opción de autorrenovación si corresponde.

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
