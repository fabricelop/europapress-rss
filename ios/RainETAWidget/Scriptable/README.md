# RainETA — instalar ahora en iPhone (sin Mac)

La vía rápida es la app gratuita [Scriptable](https://apps.apple.com/app/scriptable/id1405459188), que aloja widgets reales de iOS. Este script usa ubicación actual o coordenadas elegidas, muestra **empieza en / termina en** y una cuenta atrás dinámica.

1. Instala Scriptable desde el App Store y crea un script nuevo llamado **RainETA Lluvia**.
2. Copia el contenido completo de `RainETA-Lluvia.js` y ejecútalo una vez **dentro de Scriptable** para autorizar ubicación y comprobar la vista previa.
3. En el iPhone mantén pulsada la pantalla de inicio → **Editar > Añadir widget > Scriptable** → formato pequeño.
4. Mantén pulsado el widget añadido → **Editar widget** → selecciona el script **RainETA Lluvia**.
5. Deja vacío el campo **Parameter** para la ubicación actual, o escribe `40.4168,-3.7038|Madrid` para una ubicación fija (latitud,longitud|etiqueta). La última ubicación autorizada se conserva localmente como fallback.

**Sin producción nueva:** mientras `/api/rain-widget` no esté desplegado, el script consulta directamente Open-Meteo como segunda vía. Después de validar una preview, puedes añadir su origen HTTPS en `RAINETA_PREVIEW`; al publicar la API RainETA el mismo script aprovechará radar AEMET y modelo. No es necesario pagar por una API meteorológica.

**Limitaciones:** las predicciones de Open-Meteo a 15 minutos en Iberia pueden ser interpolaciones de información horaria; por eso mostramos ±30 min, no exactitud de minuto. El reloj visual puede contar continuamente pero Apple controla las consultas de datos nuevos del widget. Si iOS retrasa la actualización más allá de la hora prevista, la cifra puede empezar a contar hacia arriba hasta el próximo refresco. Consulta el radar / los avisos oficiales ante lluvia intensa.
