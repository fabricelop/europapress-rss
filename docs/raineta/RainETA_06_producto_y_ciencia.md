# RainETA 0.6 — Experiencia dinámica y contrato científico

Fecha: 13-10-2026

## Realmente implementado en iOS 0.6
- Inicio: contador en pantalla que progresa **cada segundo** hasta el próximo inicio/fin de lluvia previsto a partir de la información que ya se ha descargado. Cambiar el número NO significa consultar al proveedor cada segundo.
- Gráfica de 30, 60, 120 minutos con una barra visual por minuto, escala de intensidad física uniforme, selección táctil de barra, valor convertido a mm/h y probabilidad del modelo disponible. **INTERPOLACIÓN VISUAL entre puntos del pronóstico de 15 minutos**, no observación/nowcast independiente a resolución de un minuto.
- 3 horas: columnas cada 15 min, categorías de intensidad, probabilidad por intervalo y duración prevista con señal de lluvia.
- Hasta 7 días: barras horarias y detección de franjas de lluvia por fecha (HH:mm–HH:mm) con máximo y acumulado de cada episodio, cálculo directo de los datos horarios. Los episodios a partir del segundo día tienen elevada incertidumbre.
- Lista «Mis lugares»: tabla compacta, señal SÍ/NO de lluvia según modelo para cada ubicación, cuenta atrás local actualizada cada 30 s, temperatura actual, alerta de datos caducados tras 20 min. Se conserva todo el catálogo anterior en UserDefaults.
- Guardar la ubicación GPS fija con el nombre que el usuario escriba, renombrar, eliminar, seleccionar, sin duplicar lugares por coordenadas ya almacenadas.
- Tercera pestaña Ajustes: activar/desactivar ActivityKit, permiso GPS siempre, política de actualización cuando está visible, horizonte inicial de gráfica, fuentes y precisión.
- Lectura georreferenciada OPERA COG en Swift ya incorporada, pero **aún no activada en el radar visual** porque falta validación científica en España y en el iPhone.

## Horizonte útil del futuro
- 0 a +15 min: varios episodios OPERA europeos reales retrospectivos mejoraron una referencia fija; se ha verificado el fundamento, no fiabilidad general española.
- +15 a +30 min: objetivo científico siguiente, con validación en varias lluvias españolas. No aprobado aún.
- +30 a +60 min: requiere estimación de crecimiento/disipación e incertidumbre; no basta prolongar la velocidad de 15 min.
- +60 a +120 min: combinación (blending) de radar/advección con AEMET HARMONIE-AROME o campos numéricos; presentar tramos de 5 min **solo si existe una simulación/nowcast validado para ellos**; si no, interpolación explícita en pasos de 15 min.
- +2 a +48h: alta resolución regional AEMET según acceso, tratamiento de escalas, metadatos y almacenamiento. No anunciar 5 min independientes a ese plazo.

## Validaciones imprescindibles
- Detección de 3–5 episodios reales en España, 3 y 6 barridos 5-min, evalúar +5/+10/+15/+30/+60 y bias/error llegada frente a persistencia y suavizado sin advección.
- APP iOS captura representativa de ciudad lluviosa + seca, misma cámara mapa al alternar Ahora +15 +60 +120, inspección pixel, no manchas grises.
- Estudios de batería (descarga 3×3.6 MB OPERA, memoria ImageIO ~133 MB por frame), MapKit color nodata transparente, tiles fade-free y coherencia zoom hasta 16.
- API no debe mostrar valor de estado SÍ/NO como observación cuando deriva de un pronóstico modelo.
- Test XCTest sobre períodos, interpolación, límites de datos, hora y nombres guardados; compilar IPA sin firma e inspeccionar la extensión En Vivo.

## Comercialización: licencias
- API gratuita de Open-Meteo **exclusivamente no comercial** aunque sus datos llevan CC BY 4.0; comercialización requiere cuenta comercial/servidor propio respetando condiciones.
  https://open-meteo.com/en/pricing
- RainViewer API gratuita orientada a uso personal, educativo y comunitario pequeño; integración comercial requiere permiso/condiciones del proveedor.
  https://www.rainviewer.com/api.html
- OPERA compuestos disponibles CC BY 4.0 con atribución, validar condiciones individuales.
  https://eumetnet.github.io/openradardata-documentation/1-ORD-API-overview/
- No confundir prototipo descargable y producto comercial/operacional. La comercialización exige términos meteorológicos, coste de operación, calidad medible y política de privacidad.

No se activará en producción un horizonte de +120 min como «radar futuro de 5 min» sin datos que lo respalden.
