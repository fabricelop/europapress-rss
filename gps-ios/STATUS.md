# Estado — 11 octubre 2026 · v0.3 GPS inteligente

## Nueva tanda v0.3 (compilación y tests automáticos confirmados; instalación física pendiente)
- [x] [Build iOS Release verde, GitHub Actions run 38122579172](https://github.com/fabricelop/europapress-rss/actions/runs/38122579172), IPA sin firmar artifact 11696021211 (fecha 11/10/2026); verificados Info.plist 1.0.3 (build 3), bundle ID es.mimapadeltiempo.app y permiso Core Motion.
- [x] [XCTest iOS Simulator verde, run 38122779881](https://github.com/fabricelop/europapress-rss/actions/runs/38122779881): 23 tests ejecutados, 0 errores. Incluye migración JSON → SQLite y comparación de totales/nombres; batería y segundo plano siguen sin verificación física.

- Motor inteligente: precisión máxima en desplazamientos; reposo de menor consumo tras 10 minutos inmóvil, con detección asistida por Core Motion cuando iOS entrega actividad.
- Interruptor «Voy a moverme» en el mapa y en Ajustes: entra de inmediato en máxima precisión; se apaga tras parada prolongada detectada o por decisión manual; seguimiento automático permanece activo.
- Persistencia SQLite WAL: migración transaccional desde el JSON de versiones anteriores, dejando ese archivo sin borrar para recuperación. Guardados incrementales, sin reescribir todo el GPS en cada actualización. Se conservan datos y nombres si la migración termina correctamente; existe modo de respaldo JSON si no puede abrirse SQLite.
- Conservación selectiva de posiciones casi redundantes durante estancias. El tiempo se asigna por intervalos entre muestras recibidas; si hay un hueco superior a 180 s, se registra incertidumbre, no se inventa permanencia.
- Histeresis ante oscilaciones de cuadrícula; el comienzo de estancia usa cuadrícula estabilizada.
- Mapa de cuadrículas independiente de teselas: con la red desconectada aparece un fondo básico propio; también se puede activarlo manualmente desde Ajustes.
- Posiciones GPS trasladadas al diagnóstico técnico, con modo, precisión y estado SQLite; panel principal sin el contador de coordenadas.
- Diario: división manual de episodios por punto central GPS y opción de deshacer la división («Unir de nuevo»); los tiempos originales no se modifican. Todavía no se pueden fusionar arbitrariamente dos episodios clasificados automáticamente.
- [x] Tests de estados GPS, migración JSON/SQLite, recorte de intervalos y divisiones: 23 XCTest superados en simulador iOS.
- **Sin Vercel. Sin cambios en main, AquíEstuve ni TTendencias/TTiTTulares.**

## Límites que requieren pruebas con el teléfono
- La reactivación de Core Motion al caminar/conducir en segundo plano no es instantánea ni garantizada; comprobar recorrido real con pantalla bloqueada.
- Una muestra nueva tras un largo intervalo sin GPS no prueba por sí sola la permanencia durante todo el hueco.
- SQLite es persistencia incremental, pero el modelo aún carga toda la historia en memoria; quedan indexación y consultas paginadas para muchos años.
- El mapa básico usa cuadrículas locales y no incorpora calles ni satélite. El interruptor offline no descarga cartografía.
- GPX importado reconstruye con reglas conservadoras; falta endurecer importaciones masivas y solapamientos.
- Batería real y pérdida de señal no medidas en iPhone para v0.3.
- Falta backup cifrado en iCloud, widgets, edición de zonas libres, avisos GPS graves, estadísticas por nombres administrativos y edición generalizada de trayectos.

---

## En desarrollo para la próxima IPA (pendiente de compilación y prueba)
- [x] Código: formato legible de duración sin prefijos de cero (1 min 25 s, 2 h 4 min).
- [x] Código: icono propio generado como AppIcon en el build iOS.
- [x] Código: panel renovado de estadísticas con tarjetas, ranking y barras.
- [x] Código: selección de periodo Todo/Hoy/7 días/Mes/Año en mapa y estadísticas.
- [x] Código: comparación entre dos intervalos por cuadrículas, sin alterar datos originales.
- [x] Código: español en el diario de días y raíz de la aplicación.
- [x] Código: acceso protegido mediante autenticación iOS opcional (Face ID o código).
- [x] Código: modo adaptativo de colores funcional y selector Permanencia/Exploración más claro.
- [x] Código: restaura inicio de estancia local y detecta cortes largos de señal GPS.
- [x] Compilación Xcode Release iOS 17+ correcta del nuevo bloque: [GitHub Actions run 38120719702](https://github.com/fabricelop/europapress-rss/actions/runs/38120719702), artefacto 11695925258 `MiMapaDelTiempo-unsigned-IPA` (11/10/2026). ZIP e IPA desempaquetados y comprobados, Info.plist `es.mimapadeltiempo.app`, `Assets.car` con AppIcon, modo de ubicación en segundo plano. Pendiente de probar en iPhone.
- [x] La opción de territorio no visitado se muestra desactivada hasta implementar el sombreado real; no es funcional.

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

## Instalación en iPhone comunicada por el usuario · 11/10/2026
- [x] El usuario confirmó que Mi Mapa del Tiempo v0.2 se actualizó correctamente desde Windows/Sideloadly tras **cerrar completamente la app abierta en el iPhone**. La instalación previamente detenida en «Installing… 90%» avanzó inmediatamente. Este diagnóstico es observación del usuario, no una reproducción automatizada.
- [ ] Comprobar en el dispositivo los nuevos filtros, Face ID y continuidad GPS durante una vuelta con pantalla bloqueada.
- [ ] Se inició un build de diagnóstico con CFBundleVersion 2 antes de recibir la confirmación de la causa real; **no se necesita instalar esa compilación** para resolver este incidente.

## Limitaciones verificadas
- [x] Historial de compilación: run #5 versión anterior [38119202534](https://github.com/fabricelop/europapress-rss/actions/runs/38119202534). Nueva versión: [38120719702](https://github.com/fabricelop/europapress-rss/actions/runs/38120719702) Xcode build correcto, IPA sin firmar válida. No probada aún en iPhone.
- [ ] Probar actualización continua, consumo y precisión con iPhone bloqueado: requiere iPhone.
- [x] Sin Vercel: compilación e instalación de app nativa a través de GitHub Actions y Sideloadly (no se despliega web).
- [ ] Pruebas masivas de importación y prevención de todos los solapamientos.
- [x] MapPolyline segmentado en el mapa y la reproducción usando GPSRouteSegments: no unir interrupciones GPS ni saltos físicamente imposibles.
- [ ] La vista web es experimental y Safari puede suspenderla en segundo plano.

## Pendientes técnicos importantes
1. Instalar la IPA validada del nuevo run mediante Sideloadly, sin desinstalar la app anterior y tras exportar JSON; probar el GPS bloqueado, estancia y trayecto real.
2. SQLite y mecanismos de continuidad de registro en background.
3. Gestión robusta de solapamientos en importación, pérdida de señal y auditoría de correcciones.
4. Mapa básico de cuadrículas offline, territorios por descubrir, polígonos dibujables y cálculo zonal retroactivo.
5. Ya hay filtros rápidos de fecha y comparación por cuadrículas, pendientes: fechas arbitrarias en mapa, gráficos de zonas geográficas, animación completa y rendimiento a gran escala.
6. Face ID implementado en el código, sin validar en iPhone. Pendientes: widgets, copia cifrada recuperable en iCloud y avisos GPS graves.
7. Firmar IPA en Windows mediante Sideloadly y probar GPS en dispositivo real; distribución TestFlight no forma parte de la primera prueba.

## Seguridad
Todos los datos de ubicación permanecen locales en ambos prototipos, sin llamadas de telemetría de la aplicación. El código en GitHub es público; no contiene ubicaciones reales del usuario.
