# RainETA v0.3

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

## Radar
RainViewer aporta los últimos barridos. RainETA descarga una imagen centrada en la ubicación, genera una máscara de precipitación en el dispositivo, calcula traslación entre barridos y proyecta el píxel de la ubicación cada 5 minutos hasta 120 minutos.

El radar se refresca cada 5 minutos mientras la PWA está visible; los modelos se cachean durante 20 minutos para no malgastar ancho de banda ni CPU.

## Arquitectura y coste
RainETA no añade ninguna Serverless Function al proyecto Vercel. Las consultas se realizan directamente desde el navegador a APIs públicas con CORS y el nowcasting se ejecuta en el dispositivo. Esto evita el límite de funciones del plan Hobby y reduce Fluid Active CPU.

## Fuentes
- Open-Meteo Forecast / Ensemble / Geocoding.
- RainViewer Weather Maps API.
- OpenStreetMap para mapa base.

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
