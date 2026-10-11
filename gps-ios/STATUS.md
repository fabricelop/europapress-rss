# Estado — 11 octubre 2026

## Ya guardado
- [x] Rama independiente feature/mi-mapa-del-tiempo-ios, sin modificar main.
- [x] Prototipo web de una página, sin dependencias JavaScript externas.
- [x] Seguimiento navegador en primer plano, representación canvas de cuadrículas, contadores, mapa de permanencia/exploración, gestión local, importar GPX, exportar JSON y datos de ejemplo.
- [x] Código de app SwiftUI iOS 17+ con alta precisión CoreLocation, permiso always y modo background location, MapKit, acumulación, archivos locales, un diario básico y GPX.
- [x] Configuración XcodeGen y pruebas de geometría/formato (sin ejecutar en Mac).
- [x] Nuevo clasificador preliminar de trayectos y estancias en GPSHistoryTimeline.swift; solo presentación, sin alterar tiempos.
- [x] Diario por días y episodios GPS integrado en la pestaña Histórico mediante GPSDiaryShell, con acceso a GPSDayView y GPSReplayShell.
- [x] Vista GPSDayView: duración de episodios recortada a la fecha consultada al cruzar medianoche, sin dividir el episodio original.
- [x] Reproducción: la posición ya no avanza artificialmente entre dos puntos si hay más de 180 s sin GPS o salto físicamente inverosímil; se mantiene la última posición conocida hasta la siguiente muestra.
- [x] PlaybackGapPolicy.swift con umbral explícito de 180 s y nota de validación.
- [x] Comprobación local en Linux con swiftc (7 verificaciones PASS: divisiones por pérdida de señal, rechazo de teletransporte, posición GPS ausente, interpolación válida y límites de reproducción). No equivale a compilar la app iOS.

- [x] Workflow `.github/workflows/mi-mapa-del-tiempo-ios-build.yml` añadido en rama aislada: macOS GitHub Actions, XcodeGen, compilación iOS sin firma y empaquetado IPA; NO utiliza Vercel.
- [x] Se recuerda la preferencia de seguimiento activo, se intenta reanudar al abrir la app y se fuerza guardado al pasar a segundo plano. iOS no garantiza ejecución continua.
- [x] Tests XCTest de separación de rutas y huecos GPS añadidos a la rama.
- [x] Instrucciones para Windows + Sideloadly añadidas a README.md.

## Limitaciones verificadas
- [x] Compilación nativa iOS Release correcta en GitHub Actions, run #5 del 11/10/2026, [ver ejecución](https://github.com/fabricelop/europapress-rss/actions/runs/38119202534). Artefacto **MiMapaDelTiempo-unsigned-IPA**, ID 11694464174, 219461 bytes ZIP, disponible en GitHub hasta 18/10/2026. No está firmado ni probado en iPhone.
- [ ] Probar actualización continua, consumo y precisión con iPhone bloqueado: requiere iPhone.
- [ ] Hosting HTTPS del prototipo: Vercel devolvió HTTP 402 resource_creation_blocked por límite del equipo; no se creó ningún proyecto ni despliegue.
- [ ] Pruebas masivas de importación y prevención de todos los solapamientos.
- [x] MapPolyline segmentado en el mapa y la reproducción usando GPSRouteSegments: no unir interrupciones GPS ni saltos físicamente imposibles.
- [ ] La vista web es experimental y Safari puede suspenderla en segundo plano.

## Pendientes técnicos importantes
1. Descargar la IPA del run verde, firmarla con Sideloadly y probarla en un iPhone físico. Registrar resultados de instalación y localización.
2. SQLite y mecanismos de continuidad de registro en background.
3. Gestión robusta de solapamientos en importación, pérdida de señal y auditoría de correcciones.
4. Mapa básico de cuadrículas offline, polígonos dibujables y cálculo zonal retroactivo.
5. Filtros, reproducción completa y comparación entre periodos.
6. Widgets, Face ID, copia cifrada con recuperación en iCloud, avisos GPS graves.
7. Firmar IPA en Windows mediante Sideloadly y probar GPS en dispositivo real; distribución TestFlight no forma parte de la primera prueba.

## Seguridad
Todos los datos de ubicación permanecen locales en ambos prototipos, sin llamadas de telemetría de la aplicación. El código en GitHub es público; no contiene ubicaciones reales del usuario.
