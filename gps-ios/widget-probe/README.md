# Diagnóstico iPhone sin modificar Mi Mapa del Tiempo

1. Instala «WidgetProbe-unsigned.ipa» con Sideloadly y el mismo Apple ID de siempre.
2. Abre «Diagnóstico Widget» y pulsa «Comprobar instalación».
3. Busca «Diagnóstico Widget» en la galería del escritorio; debería mostrar «WIDGET OK».
4. Pulsa «Crear actividad de prueba» y bloquea el iPhone. Debería mostrar «ACTIVITY OK».
5. Envía capturas del resultado (presencia en la galería, bloqueo y texto del diagnóstico).

Esta app no tiene App Group y no accede a ubicación. Sirve para aislar problemas
de la firma y registro de la extensión frente al intercambio de datos de Mi Mapa.
Si ActivityKit dice active, eso **no** verifica por sí solo que iOS la haya dibujado.
