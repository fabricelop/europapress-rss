# RainETA Consenso — Widget Scriptable para iPhone SIN Vercel

## Qué es y qué NO es

Widget con el **mismo núcleo de consenso** de `vercel-webhook/rain/core.js` en RainETA (funciones `aggregateEnsembleModel`, `buildConsensus`, `detectRainEvents` y `chooseNextEvent` copiadas sin alterar su lógica), adaptado a Scriptable. No depende de Vercel ni de un servidor propio: todas las consultas de datos salen directamente desde el iPhone a los endpoints públicos de Open-Meteo.

**No es una exportación de la predicción completa de RainETA**: no incluye el flujo óptico del radar de RainViewer, AEMET/OPERA ni el procesamiento de AEMET HARMONIE que RainETA utiliza en su versión web. Por tanto, *no debe presentarse como nowcasting completo, radar observado ni como cuenta atrás exacta al minuto*. La hora de inicio/final procede de eventos detectados en un **consenso horario**, con margen orientativo de ±60 minutos. No garantiza mayor precisión que el modelo individual; debe validarse contra observaciones.

Modelos que el script intenta consultar: ECMWF IFS, DWD ICON, Météo-France ARPEGE y UKMO (deterministas); ICON-EU EPS, NOAA GEFS y ECMWF AIFS ENS (ensembles). Solo cuenta los modelos que realmente respondieron; exige 2 como mínimo. Los datos son pronósticos meteorológicos reales proporcionados por modelos publicados a través de Open-Meteo, no mediciones de lluvia en tu calle. El porcentaje mostrado es el **indicador probabilístico de consenso RainETA**, basado en ensembles y señales deterministas, no una probabilidad de lluvia calibrada o certificada.

## Instalación

1. Abre **[RainETA-Consenso.js](RainETA-Consenso.js)** desde el móvil y copia todo el contenido.
2. En Scriptable, crea un script nuevo llamado `RainETA Consenso` y pega el código. Puedes conservar el script anterior `RainETA Lluvia` para comparar ambos resultados.
3. Ejecuta el script dentro de Scriptable: se mostrará una vista previa mediana.
4. Mantén pulsada la pantalla de inicio → añadir widget → Scriptable mediano o grande → **Editar widget** → `Script = RainETA Consenso`.
5. En **Parameter** puedes escribir una ciudad como `Madrid`, `Bilbao`, `Sevilla, España` o coordenadas con etiqueta `40.4168,-3.7038|Madrid`. Campo vacío usa GPS. La ubicación se guarda en el propio iPhone como alternativa cuando falla GPS.

## Pantalla

- Pequeño: cuenta atrás estimada a comienzo o final de precipitación, o aviso de que no hay episodio confirmado. Fuente horaria, sin radar.
- Mediano o grande: cuenta atrás + 12 barras de lluvia previstas.
- **Encima de cada barra:** porcentaje probabilístico del consenso RainETA.
- **Altura/color:** precipitación media prevista para ese tramo de una hora, equivalente en mm/h.
- **Debajo:** mm con un decimal y hora de inicio de esa hora en la zona horaria del iPhone.
- Pie: hora de actualización, número de modelos y familias independientes. `Guardado HH:MM` indica uso de caché.
- Intensidades: menos de 0,1 mm/h (seco), 0,1–0,5 (muy débil), 0,5–2,5 (débil-moderada), 2,5–7,5 (fuerte), más de 7,5 (muy fuerte).

La previsión se recalcula cuando Scriptable ejecuta el widget. El script solicita una nueva actualización pasados **20 minutos**, pero iOS puede espaciarla más. Los datos guardados se pueden reutilizar hasta 2 horas si falla la red; desde los 35 minutos el contador se oculta para no dar una ETA desfasada. El gráfico también marca la condición `Guardado`.

Atribución: [Weather data by Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).

## Verificación y límites

Pruebas simuladas con 4 modelos deterministas y 3 ensembles: 12 barras (36 rótulos) en widgets mediano/grande, pequeño sin gráfico, cuenta atrás, caché sin conexión, fallback sin ensembles, 8 peticiones directas (7 modelos + precipitación actual). Sintaxis del script comprobada. **Pendientes**: ensayo de API real, comprobación visual en iPhone y medición de exactitud de la previsión frente al tiempo observado. Los nombres de modelos y endpoints pueden cambiar; los fallos se descartan y el número efectivo de fuentes se muestra en pantalla.

## Cómo obtener el RainETA completo

Para disponer del nowcast de AEMET/OPERA/RainViewer y AEMET HARMONIE exactamente como RainETA web, hay que exponer el resultado de su cálculo como un JSON accesible desde el iPhone. Ese servicio podría ejecutarse en un PC propio accesible de forma segura o en un backend distinto de Vercel; no se puede obtener solamente instalando un widget de Scriptable que lea los datos del navegador de otra app.
