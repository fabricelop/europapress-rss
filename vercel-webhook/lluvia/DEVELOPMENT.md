# Lluvia — notas de desarrollo

## 2026-10-06

Mejora aplicada al cálculo de episodios y su incertidumbre:

- La API meteorológica se solicita en `unixtime` para evitar interpretar como hora del dispositivo timestamps locales del punto consultado.
- Cada modelo (ECMWF IFS, DWD ICON y GFS) se segmenta primero en episodios propios.
- Una pausa seca aislada de una hora se considera parte del mismo episodio para evitar falsos inicio/fin por intermitencia mínima.
- Las ventanas de inicio y fin se calculan sólo con el episodio de cada modelo que realmente solapa el episodio consensuado. Esto evita que una lluvia posterior no relacionada ensanche artificialmente la ventana de inicio.
- La confianza incorpora cobertura de modelos, dispersión temporal del inicio, horizonte y dispersión de intensidad.
- La UI móvil muestra ahora inicio, fin, duración, pico mediano y número de modelos que respaldan cada episodio.
- Los mensajes de error se neutralizan antes de insertarlos en HTML.

### Comprobaciones

Se revisaron explícitamente los casos de episodio intermitente de una hora, episodios posteriores no relacionados y modelos sin episodio coincidente. La lógica ya no usa el primer valor húmedo posterior como supuesto inicio del episodio actual.

### Próximos límites / siguiente prioridad

El principal límite sigue siendo 0–2 h: los tres modelos son NWP y no sustituyen radar/observación. Próxima mejora prioritaria: integrar una fuente radar/nowcast disponible para el punto, aplicar pesos que transicionen de observación/radar a NWP según horizonte y guardar predicciones resumidas para validación retrospectiva contra observaciones sin aumentar de forma agresiva el coste de Vercel/GitHub.