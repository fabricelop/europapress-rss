# RainETA v0.2

PWA estática y móvil para responder a una pregunta: **cuándo empieza y cuándo termina la lluvia en un punto concreto**.

## Diseño
- **0–2 h:** analiza varios barridos de RainViewer en el navegador, estima traslación de la precipitación y proyecta la llegada al punto. Si el movimiento no es suficientemente estable, no inventa una ETA.
- **0–8 h:** añade guía de precipitación a 15 minutos de Open-Meteo, marcada explícitamente como potencialmente interpolada en España.
- **0–72 h:** combina modelos deterministas y ensembles de familias independientes (ECMWF, DWD, NOAA, Météo-France, CMC y UKMO cuando están disponibles).
- Muestra una ventana/margen y confianza, no una falsa precisión.

## Por qué no usa API propia de Vercel
El proyecto Hobby ya está cerca del límite de Serverless Functions. RainETA llama directamente desde el navegador a APIs públicas con CORS y hace el nowcasting en el dispositivo, por lo que añade **0 funciones serverless** y casi 0 CPU activa de Vercel.

## Fuentes
- Open-Meteo Forecast / Ensemble / Geocoding.
- RainViewer Weather Maps API (radar).
- OpenStreetMap (mapa base).

AEMET queda preparada como futura capa adicional: OpenData exige API key y desde julio de 2026 las nuevas claves caducan a los 3 meses, por lo que no se embebe ninguna clave en el navegador.

## Limitaciones honestas
- El nowcast por traslación funciona mejor con bandas organizadas que con tormentas que nacen/desaparecen rápidamente.
- La guía de 15 min puede ser interpolada fuera de regiones con modelo nativo a 15 min.
- El radar de RainViewer no tiene SLA; la app degrada a modelos si falla.
