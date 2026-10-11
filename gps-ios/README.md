# Mi Mapa del Tiempo — primera versión

Proyecto personal para iPhone. Cuadrículas de aproximadamente 100 × 100 metros, contador de tiempo histórico acumulado y estancia actual, incluyendo desplazamientos. La hora se conservará internamente en UTC; la aplicación final mostrará la hora local de cada lugar.

## Qué contiene esta rama

- native/: aplicación SwiftUI inicial para iOS 17+ con CoreLocation de máxima precisión, mapa MapKit, acumulación entre fijaciones GPS, datos JSON locales, estadísticas iniciales, diario por días/trayectos, reproducción con huecos explícitos y GPX.
- preview/index.html: prototipo web autónomo para probar cuadrículas, GPS en primer plano, mapa básico sin calles, modos permanencia/exploración, un recorrido de demostración, estadísticas, importación GPX y exportación JSON.

## Prueba en iPhone sin Mac propio ni Vercel (Windows + Sideloadly)

La app es **nativa SwiftUI**, no una web. El repositorio contiene el workflow
`.github/workflows/mi-mapa-del-tiempo-ios-build.yml`, que compila sobre el
runner `macos-15` de GitHub Actions y empaqueta la IPA **sin firmar**.
No utiliza servidores de Vercel, alojamiento web ni despliegues.

1. Consultar [GitHub Actions](https://github.com/fabricelop/europapress-rss/actions),
   localizar **Mi Mapa del Tiempo - IPA iPhone** y abrir el último run VERDE
   de la rama `feature/mi-mapa-del-tiempo-ios`. Si no aparece un run correcto,
   no hay una IPA validada todavía.
2. Abrir **Artifacts → MiMapaDelTiempo-unsigned-IPA** y descargar el ZIP.
   Extraer `MiMapaDelTiempo-unsigned.ipa` en Windows.
3. Conectar el iPhone al PC (confiar en el equipo y conservar Modo Desarrollador).
4. Arrastrar la IPA a **Sideloadly**, elegir el iPhone y firmarla con una
   cuenta Apple autorizada. Una cuenta Apple gratuita suele requerir
   renovar la firma cada 7 días.
5. Abrir **Mi Mapa del Tiempo** en el iPhone. En Ajustes, pulsar
   **Iniciar GPS de máxima precisión** y autorizar localización precisa
   y «Siempre». Comprobar el estado del GPS y que las cuadrículas y
   contadores se actualizan en Mapa, incluso al desplazarse.
6. Probar primero con pantalla encendida y después bloqueada;
   volver a abrir la app y verificar el historial, continuidad
   y exportación. Si iOS restringe el segundo plano, recoger
   el diagnóstico sin dar por registrada ninguna duración desconocida.

La IPA no está firmada por GitHub: **la firma se hace en Windows con
Sideloadly**. El proyecto debe superar una compilación Xcode real antes
de considerar instalable cualquier artefacto. Una IPA compilada no garantiza
seguimiento 24/7: iOS puede suspender o cerrar el proceso.

Archivos relevantes:
- [Código nativo](native/Sources/MiMapaDelTiempoApp.swift)
- [Diario GPS](native/Sources/GPSDiaryViews.swift)
- [Reproducción](native/Sources/GPSReplayShell.swift)
- [Estado y limitaciones](STATUS.md)

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
