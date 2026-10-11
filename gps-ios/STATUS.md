# Estado — 11 octubre 2026

## Ya guardado
- [x] Rama independiente feature/mi-mapa-del-tiempo-ios, sin modificar main.
- [x] Prototipo web de una página, sin dependencias JavaScript externas.
- [x] Seguimiento navegador en primer plano, representación canvas de cuadrículas, contadores, mapa de permanencia/exploración, gestión local, importar GPX, exportar JSON y datos de ejemplo.
- [x] Código de app SwiftUI iOS 17+ con alta precisión CoreLocation, permiso always y modo background location, MapKit, acumulación, archivos locales, un diario básico y GPX.
- [x] Configuración XcodeGen y pruebas de geometría/formato (sin ejecutar en Mac).
- [x] Nuevo clasificador preliminar de trayectos y estancias en GPSHistoryTimeline.swift; solo presentación, sin alterar tiempos.
- [ ] Nuevo diario por días todavía no integrado en la pestaña Histórico.

## Limitaciones verificadas
- [ ] Compilar y ejecutar SwiftUI en Xcode: no hay Mac/Xcode en este entorno.
- [ ] Probar actualización continua, consumo y precisión con iPhone bloqueado: requiere iPhone.
- [ ] Hosting HTTPS del prototipo: Vercel devolvió HTTP 402 resource_creation_blocked por límite del equipo; no se creó ningún proyecto ni despliegue.
- [ ] Pruebas masivas de importación y prevención de todos los solapamientos.
- [ ] La vista web es experimental y Safari puede suspenderla en segundo plano.

## Pendientes técnicos importantes
1. SQLite y mecanismos de continuidad de registro en background.
2. Gestión robusta de solapamientos en importación, pérdida de señal y auditoría de correcciones.
3. Mapas offline nativos, polígonos dibujables y cálculo zonal retroactivo.
4. Reproducción animada, filtros y comparación entre periodos.
5. Widgets, Face ID, copia cifrada con recuperación en iCloud, avisos GPS graves.
6. Compilación en Xcode, tests en dispositivo y distribución TestFlight.

## Seguridad
Todos los datos de ubicación permanecen locales en ambos prototipos, sin llamadas de telemetría de la aplicación. El código en GitHub es público; no contiene ubicaciones reales del usuario.
