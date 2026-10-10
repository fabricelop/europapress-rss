# Mi Mapa del Tiempo — primera versión

Proyecto personal para iPhone. Cuadrículas de aproximadamente 100 × 100 metros, contador de tiempo histórico acumulado y estancia actual, incluyendo desplazamientos. La hora se conservará internamente en UTC; la aplicación final mostrará la hora local de cada lugar.

## Qué contiene esta rama

- native/: aplicación SwiftUI inicial para iOS 17+ con CoreLocation de máxima precisión, mapa MapKit, acumulación entre fijaciones GPS, datos JSON locales, estadísticas iniciales, diario de ubicaciones y GPX.
- preview/index.html: prototipo web autónomo para probar cuadrículas, GPS en primer plano, mapa básico sin calles, modos permanencia/exploración, un recorrido de demostración, estadísticas, importación GPX y exportación JSON.

## Probar la app nativa (Mac necesario)

1. Descargar los archivos de la carpeta gps-ios/native.
2. En un Mac, instalar Xcode y XcodeGen (github.com/yonaskolb/XcodeGen).
3. En Terminal, dentro de native, ejecutar: xcodegen generate
4. Abrir MiMapaDelTiempo.xcodeproj, seleccionar un equipo de firma (Signing & Capabilities) y un identificador de paquete propio.
5. Conectar un iPhone, seleccionar ese destino y pulsar Run.
6. Conceder los permisos de localización precisa y siempre, probar andando, en coche y con pantalla bloqueada.

No se ha compilado en Xcode ni hay IPA/TestFlight firmado. Para la prueba en iPhone hace falta Mac, cuenta Apple y compilación/firma.

## Probar la vista web

Debe servirse por HTTPS o localhost para solicitar permisos GPS. Abrir el HTML directamente desde archivos del iPhone puede impedir la geolocalización. Desde Ajustes se puede iniciar GPS o cargar un recorrido ficticio. El navegador puede detener las actualizaciones al bloquear el móvil; no usar la vista web para grabar 24 horas.

## Datos y límites

La malla usa bandas geográficas estables de unos 100 metros, longitud ajustada a la latitud. Los registros originales de GPS y segmentos reconstruidos se guardan separados en las fuentes de la app nativa; no se inventan tiempos para huecos de GPS. El archivo GPX requiere puntos con fechas y coordenadas.

El prototipo web guarda datos en el navegador, que pueden perderse si se borran los datos de Safari. La app nativa guarda JSON local atómico, una primera solución que deberá reemplazarse por SQLite para históricos grandes.

## Especificación completa acordada

- Mapa a pantalla completa con tarjeta flotante minimizable y recordar zona/zoom.
- Permanencia por defecto, exploración opcional, mapa no visitado oscurecible.
- Contadores por casilla donde quepan; escalas cromáticas fijas universales y adaptativas.
- Mapas histórico, animado y comparaciones de fechas; trayectos por día e individuales con rutas opcionales.
- Estadísticas por barrios, ciudades, regiones, países y zonas de perímetro libre.
- Corrección automática GPS y manual, sugerencias silenciosas de lugares habituales a confirmar.
- Importación histórica solo GPS, Face ID configurable, widgets iPhone.
- Datos primarios en iPhone y copias cifradas iCloud, notificación solo incidencias GPS importantes.
- Sin conexión, mapa básico de cuadrículas, sin descargas de cartografía detallada.
- Prioridad máxima a precisión sobre batería, todo tránsito incluido, hora local para diario.

Estas son decisiones de producto; la primera versión no implementa todavía todo. Ver STATUS.md.
