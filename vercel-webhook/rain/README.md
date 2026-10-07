# RainETA v0.17.6

PWA estática y móvil para responder a una pregunta: **cuándo empieza y cuándo termina la lluvia en un punto concreto**.

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

## Quórum mínimo de modelos v0.17.6
- Una señal ordinaria respaldada por **una sola familia meteorológica** ya no crea por sí sola un episodio de lluvia con ETA: se degrada a riesgo posible.
- Con una sola familia, RainETA solo conserva el estado de lluvia prevista cuando la señal es excepcionalmente fuerte (precipitación esperada ≥0,35 mm/h o probabilidad ≥90 % con ≥0,15 mm/h).
- Con dos o más familias independientes el clasificador conserva sus umbrales normales; la confianza sigue limitada por la diversidad disponible.
- Esta protección actúa especialmente durante caídas parciales de proveedores: evita convertir la coincidencia interna de una única familia en falso consenso.

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
