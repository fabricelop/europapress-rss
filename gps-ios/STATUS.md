# Estado — 11 octubre 2026

## Ya guardado
- [x] Rama independiente feature/mi-mapa-del-tiempo-ios, sin modificar main.
- [x] Prototipo web de una página, sin dependencias JavaScript externas.
- [x] Seguimiento navegador en primer plano, representación canvas de cuadrículas, contadores, mapa de permanencia/exploración, gestión local, importar GPX, exportar JSON y datos de ejemplo.
- [x] Código de app SwiftUI iOS 17+ con alta precisión CoreLocation, permiso always y modo background location, MapKit, acumulación, archivos locales, un diario básico y GPX.
- [x] Configuración XcodeGen y pruebas de geometría/formato (sin ejecutar en Mac).
- [x] Nuevo clasificador preliminar de trayectos y estancias en GPSHistoryTimeline.swift; solo presentación, sin alterar tiempos.
- [ ] Nuevo diario por días todavía no integrado en la pestaña Histórico: la pestaña sigue mostrando el listado antiguo. El intento de modificar el archivo principal fue rechazado por el conector.
- [x] Vista GPSDayView: duración de episodios recortada a la fecha consultada al cruzar medianoche, sin dividir el episodio original.
- [x] Reproducción: la posición ya no avanza artificialmente entre dos puntos si hay más de 180 s sin GPS o salto físicamente inverosímil; se mantiene la última posición conocida hasta la siguiente muestra.
- [x] PlaybackGapPolicy.swift con umbral explícito de 180 s y nota de validación.
- [x] Comprobación local en Linux con swiftc (7 verificaciones PASS: agrupación, huecos, saltos, estancias, trayectos breves y umbrales de interpolación). No equivale a compilar la app iOS.

## Limitaciones verificadas
- [ ] Compilar y ejecutar SwiftUI en Xcode: no hay Mac/Xcode en este entorno.
- [ ] Probar actualización continua, consumo y precisión con iPhone bloqueado: requiere iPhone.
- [ ] Hosting HTTPS del prototipo: Vercel devolvió HTTP 402 resource_creation_blocked por límite del equipo; no se creó ningún proyecto ni despliegue.
- [ ] Pruebas masivas de importación y prevención de todos los solapamientos.
- [ ] La ruta dibujada en el mapa y en la reproducción aún puede unir visualmente muestras separadas por huecos; se requiere dividir MapPolyline por grupos GPS. Se intentó la corrección, pero el conector rechazó la escritura.
- [ ] La vista web es experimental y Safari puede suspenderla en segundo plano.

## Pendientes técnicos importantes
1. Integrar GPSDiaryShell en RootView (actualmente se usa TimeDiaryView), dividir polilíneas en huecos y señalar visualmente posición GPS desconocida.
2. SQLite y mecanismos de continuidad de registro en background.
3. Gestión robusta de solapamientos en importación, pérdida de señal y auditoría de correcciones.
4. Mapa básico de cuadrículas offline, polígonos dibujables y cálculo zonal retroactivo.
5. Filtros, reproducción completa y comparación entre periodos.
6. Widgets, Face ID, copia cifrada con recuperación en iCloud, avisos GPS graves.
7. Compilación en Xcode, tests en dispositivo y distribución TestFlight.

## Seguridad
Todos los datos de ubicación permanecen locales en ambos prototipos, sin llamadas de telemetría de la aplicación. El código en GitHub es público; no contiene ubicaciones reales del usuario.
