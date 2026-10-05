# RainETA

PWA minimalista centrada en una sola pregunta: **cuándo empieza y cuándo termina la lluvia en un punto concreto**.

## Arquitectura inicial

- `api/rain-forecast.js`: fusiona modelos deterministas, ensembles y metadatos de radar.
- `lib/rain-forecast-core.js`: lógica pura de consenso, incertidumbre y detección de episodios.
- `api/rain-geocode.js`: búsqueda de lugares.
- `rain/index.html`: PWA móvil, línea de 72 h, episodios y radar real.
- `test/rain-forecast-core.test.js`: pruebas unitarias del motor de consenso.

## Fuentes en v0.1

Deterministas: ECMWF IFS, ECMWF AIFS, DWD ICON, NOAA GFS, Météo-France y CMC GEM.

Ensembles: ECMWF ENS, ECMWF AIFS ENS, ICON-EU EPS, NOAA GEFS, UKMO MOGREPS-G y CMC GEPS.

Observación radar: RainViewer (últimos barridos). El nowcasting propio 0–2 h se implementará como capa separada usando secuencias de radar y estimación de movimiento.

## Principios

1. No mostrar precisión falsa: cuanto más lejano el horizonte, mayor ventana temporal.
2. Dar más peso a ensembles que a una única salida determinista.
3. Ponderar familias/modelos, no contar cada miembro como si fuera una fuente independiente.
4. Degradar con elegancia si una fuente no responde.
5. Mantener caché de servidor para reducir consumo y latencia.
