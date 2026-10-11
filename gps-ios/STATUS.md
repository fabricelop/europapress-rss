# Estado — 11 octubre 2026 · v0.3 GPS inteligente

## v0.7 — coherencia temporal y seguimiento (octubre 2026)
- Rama aislada `feature/mi-mapa-del-tiempo-ios-v07`. Sin modificaciones en `main`. Actualizar sobre la app ya instalada con el mismo identificador y el mismo Apple ID. No desinstalar; exportar JSON antes de instalar.
- **Contabilidad:** mapa, cuadrículas, lugares, estadísticas, comparación, búsqueda y snapshot para widget comparten la atribución canónica sin segundos solapados. El historial bruto preexistente se conserva sin sobrescribir; los nuevos intervalos se escriben evitando superposiciones.
- **Pantalla de mapa:** mostrar separados el tiempo del lugar y el de la cuadrícula; avance provisional limitado por frescura GPS, aviso de ubicación caducada, reloj reactivado al regresar a primer plano y solicitud puntual de ubicación. Nunca persistir segundos provisionales como confirmados.
- **Modo navegación:** botón alterna entre seguimiento con centro automático y mapa libre; manipulación del mapa permite exploración. El mapa básico sin conexión también puede seguir la ubicación.
- **Territorios:** clasificación progresiva y voluntaria al abrir la sección de estadísticas, mostrando cobertura y resúmenes parciales; consultas con Apple espaciadas y caché local. No inventar barrios.
- **Interfaz:** eliminar definitivamente «Territorio por descubrir»; conservar colores adaptados, sin leyenda.
- **Widgets:** extensión de acceso sin App Group conservada; su aparición en el iPhone con Sideloadly sigue sin estar confirmada y no se presenta como resuelta. Ajustes describen la limitación.
- **Pruebas:** tests sintéticos de solapamientos, agrupación, integridad y coherencia de periodos, build y pruebas del simulador en el flujo `mi-mapa-del-tiempo-v07-verify.yml`. El GPS físico y consumo energético requieren verificación en teléfono.

## Verificación v0.6 (11/10/2026)
- [x] [GitHub Actions: XCTest inicial de v0.6, run 38146997366](https://github.com/fabricelop/europapress-rss/actions/runs/38146997366): **44 tests, 0 fallos** y compilación Release iOS con WidgetKit.
- [x] [GitHub Actions: compilación final de v0.6, run 38147674624](https://github.com/fabricelop/europapress-rss/actions/runs/38147674624): build Release correcto, artefacto IPA 11704869636.
- [x] IPA descargada y validada: `MiMapaDelTiempo-v06-unsigned.ipa` (775878 bytes); ZIP sin errores, `CFBundleIdentifier=es.mimapadeltiempo.app`, versión `1.0.6`, build 6, `UIBackgroundModes=location`, widget embebido `MiMapaWidgets.appex` build 6 con punto de extensión WidgetKit correcto.
- [ ] Las pruebas completas del último ajuste de la interfaz estaban todavía pendientes en la ejecución v0.6 de simulador cuando se verificó la compilación final. Los 44 tests son de la versión de código inmediatamente anterior a los últimos cambios de navegación/contadores.
- [ ] Sin prueba de instalación iPhone con firma Sideloadly ni confirmación de widget en la galería. La versión v0.6 no exige App Groups y solo muestra un widget de acceso a la app si no existe snapshot compartido.
- [ ] Probar in situ: preservar 278 cuadrículas e historial, nombres Montevalle, calendarios y nombres duplicados cercanos/lejanos, botón Ver en el mapa, batería y clasificación de trayectos.


## v0.6 — calendario, lugares por nombre y comprobaciones (rama de prueba)

- Rama aislada `feature/mi-mapa-del-tiempo-ios-v06`. No modifica `main`, la versión que ya está en iPhone ni los proyectos TT/AquíEstuve.
- **Calendario por lugar/cuadrícula:** consolida los intervalos de segundos en visitas; saltos GPS cortos no se atribuyen como tiempo confirmado. Consulta por mes/año, día y visitas; el horario local del iPhone se aplica al historial.
- **Diario:** oculta episodios aislados o de cero segundos; reconoce paradas superiores a unos ocho minutos con pruebas suficientes y da etiquetas humanas de origen/destino. Clasificación heurística; no convierte huecos en movimientos inventados.
- **Búsqueda universal:** lugares, zonas e identificadores, territorios ya clasificados, desde mapa y estadísticas; muestra un representante por territorio. No geocodifica en la búsqueda.
- **Calidad de datos:** horas observadas, reconstruidas, sin ubicación fiable y solapamientos originales; vista estadística calcula cronología sin sumar segundos dos veces.
- **Lugares solo por nombre:** `NamedPlaces.migrate` conserva grupos previos y nombres, crea un lugar automáticamente al nombrar una cuadrícula. Mismo nombre cercano (<450 m entre centros) se agrupa; homónimos lejanos preguntan si unir o crear otro grupo independiente. Quitar nombre separa la cuadrícula; renombrar todo el lugar y deshacer el último cambio disponibles. Se elimina la selección manual de grupos.
- **Mapa:** se cambia el control de navegación repetida para centrar correctamente la misma cuadrícula de nuevo; al abandonar la ficha histórica modal cambia de pestaña después de cerrarla.
- **Widgets:** prueba de extensión WidgetKit **SIN capability App Group** en perfil de firma, para diagnosticar la ausencia del widget con Sideloadly gratuito. Si aparece pero no puede leer datos, muestra acceso a la app, sin inventar duración. NO afirmar que los contadores en widgets ni la galería funcionan hasta probarlo físicamente.
- **Seguridad del historial:** migración de nombres y grupos solo modifica metadatos y verifica que el número de intervalos, muestras y totales permanezca igual; el SQLite y JSON originales no se borran. Exportar copia JSON antes de instalar y actualizar sobre la misma aplicación con mismo Apple ID.
- **Limitaciones:** el ahorro de batería no está demostrado en un iPhone real, iOS puede pausar GPS en segundo plano, barrios y distritos dependen de cartografía Apple; no hay copia cifrada propia en iCloud, ni widgets dinámicos confirmados en dispositivo.


## v0.5 — verificación final (11/10/2026)
- [x] [Build Release + XCTest en macOS / Xcode, run 38141212774](https://github.com/fabricelop/europapress-rss/actions/runs/38141212774): **34 tests ejecutados, 0 fallos**.
- [x] IPA `MiMapaDelTiempo-v05-unsigned.ipa` (677877 bytes) recuperada y comprobada: ZIP válido, `CFBundleIdentifier=es.mimapadeltiempo.app`, `CFBundleShortVersionString=1.0.5`, build 5. La extensión `MiMapaWidgets.appex` está incluida, con build 5 y `com.apple.widgetkit-extension`.
- [ ] Pendiente confirmar en iPhone instalación real y preservación del historial; los tests de simulador no validan consumo GPS, geocodificación en calle ni App Group con Apple ID gratuita.
- [ ] Widget en la galería y App Group autorizado **siguen sin resolver**; no confundir extensión compilada con widget operativo en iPhone.

## v0.5 — siguiente bloque tras prueba de paseo (11/10/2026)
- Rama aislada `feature/mi-mapa-del-tiempo-ios-v05`; `main`, la rama v0.3 y la v0.4 instalada no se modifican.
- **Batería:** se sustituye `kCLLocationAccuracyBestForNavigation` por `kCLLocationAccuracyBest`, filtro de distancia 5 m en movimiento y 35 m en reposo; detección por movimiento y reanudación explícita de actualizaciones desde reposo. La autonomía real queda por medir en iPhone. El 13 % de Ajustes → Batería no es una medida causal de consumo ahorrable. Registro local de eventos `GPSPowerEvent`, disparos manuales y descansos, con diagnóstico.
- **Histórico por cuadrícula:** días desglosados en intervalos/hora y calidad de atribución, con enlace directo al mapa. Se eliminan solapamientos solo en las vistas calculadas, sin editar los datos brutos.
- **Nombres cortos:** Zona 001, 002... persistente, nombres personalizados prioritarios; migración del histórico previo a índices sin cambiar los IDs internos.
- **Lugares personalizados:** selección de cuadrículas visitadas sobre el mapa, creación, renombrado, incorporación/eliminación de casillas y estadísticas conjuntas. Un mismo segundo nunca se suma varias veces en las vistas normalizadas. El intervalo bruto por cuadrícula permanece.
- **Estadísticas:** Top 10, 25, 50 o todas; renombradas/no renombradas/todas; botón en el ranking que centra la cuadrícula en Mapa; vista Lugares y Territorios.
- **Territorios:** niveles país, comunidad/estado, provincia, municipio, distrito, barrio. Geocodificación **bajo demanda** de los centros de cuadrícula mediante CLGeocoder de Apple (12 por lote), sin costes añadidos ni descarga de mapas detallados. Caché territorial en SQLite y JSON exportado. Cuando no exista etiqueta o consulta dé error se indica pendiente, nunca se inventan barrios. Geocodificación puede ser lenta/limitada por Apple y necesitar conectividad.
- **Mapa:** escala adaptada y recorridos activos por defecto, persistentes; recorridos seleccionables por últimas 2 h, hoy, 24 h, 7 días o todo. No se añade leyenda de colores.
- **WidgetKit:** se conserva el código y extensión previa. **No se ha confirmado solución para la galería ni el App Group no autorizado** con Sideloadly/Apple gratuita. No afirmar funcionalidad del widget en dispositivo.
- **Persistencia:** nuevos campos opcionales en cabecera SQLite, compatibles con instalaciones existentes; JSON antiguo también se decodifica conservando nombres y duraciones. No desinstalar ni borrar datos. Exportar JSON antes de actualización y usar misma identidad Apple.
- **Pendientes/pruebas:** verificar compilación y XCTest macOS `.github/workflows/mi-mapa-del-tiempo-v05-verify.yml`; comprobar movilidad bloqueada, ahorro real, geocodificación y agrupación en iPhone. Resolución de barrios depende de cobertura del sistema. No hay seguimiento continuo en segundo plano garantizado.

---

## Resultado en iPhone con Sideloadly (comunicado por el usuario, 11/10/2026)
- [x] El usuario instaló la compilación de widgets (la app presenta su sección de ajustes para widgets).
- [ ] iPhone muestra **«App Group no autorizado»**: el contenedor compartido no está disponible al ejecutarse con el perfil generado por Sideloadly y Apple ID personal gratuito.
- [ ] El widget **no aparece en la galería**: comprobar primero «Advanced Options → Remove App Extensions (PlugIns)» de Sideloadly; el estado de App Group y la ausencia de widget son problemas distintos.
- No volver a generar otra IPA ni recomendar desinstalar la app sin comprobar el estado de la extensión y la firma; preservar datos SQLite y copia JSON.
- App Groups requieren autorización del identificador en el perfil de aprovisionamiento tanto de la app como de la extensión; compilación Xcode sin firma y los 26 tests no validan esa autorización en el teléfono.

## Widgets iPhone — código y artefacto verificados (NO instalado todavía)
- [x] [GitHub Actions: compilación iPhone + extensión WidgetKit y XCTest, ejecución 38124014988](https://github.com/fabricelop/europapress-rss/actions/runs/38124014988), 11/10/2026: **26 pruebas, 0 fallos**. El paso de compilación iPhone y widget terminó correctamente. Artefacto 11695859793 disponible hasta 16/10/2026.
- [x] IPA experimental desempaquetada: `MiMapaDelTiempo-widgets-unsigned.ipa` (506989 bytes); aplicación `es.mimapadeltiempo.app` versión `1.0.3` build 4; extensión embebida `MiMapaWidgets.appex` con `com.apple.widgetkit-extension` y build 4.
- [ ] **Pendiente crítico:** verificar firma/instalación real con Sideloadly y cuenta Apple gratuita, y comprobar que ambos procesos pueden leer/escribir App Group en iPhone. La IPA sin firmar NO demuestra que las capacidades del perfil gratuito incluyan App Groups.
- [ ] Pendiente: revisar en el iPhone la disponibilidad de los cinco tamaños y recargas reales (WidgetKit puede retrasarlas).

- Rama de pruebas: `feature/mi-mapa-del-tiempo-ios-widgets`. La v0.3 que el usuario está probando sigue intacta en `feature/mi-mapa-del-tiempo-ios`.
- WidgetKit: widget pequeño/mediano de inicio y widgets de bloqueo rectangular, circular y en línea. Total histórico principal y última estancia secundaria. Una pulsación abre la app.
- Datos compartidos: un snapshot pequeño `TimeWidgetSnapshot` con duraciones ya asignadas, fecha de última lectura, estado de tracking y nombre de lugar **solo si el usuario lo permite**. No se comparten coordenadas ni la base SQLite entera. Por defecto los nombres de lugares permanecen ocultos.
- Actualización: petición al sistema cuando cambia la cuadrícula o el seguimiento y como máximo periódicamente (mínimo de ~5 minutos); los widgets no calculan segundos inventados ni hacen GPS propio. WidgetKit puede retrasar o limitar las actualizaciones.
- Requiere `group.es.mimapadeltiempo.widgets` en los entitlements de la app y de su extensión. **Bloqueo externo por verificar**: la cuenta Apple gratuita/Sideloadly debe proporcionar un perfil de aprovisionamiento compatible con App Groups a ambos targets; la compilación sin firma NO demuestra que pueda firmarse o instalarse. Si el grupo no está disponible, los widgets muestran el estado vacío, nunca cifras falsas.
- Workflow macOS independiente: `.github/workflows/mi-mapa-del-tiempo-widgets-verify.yml` solo en la rama de widgets; comprueba compilación iOS, existencia de .appex y XCTest. No usa Vercel.
- Antes de una eventual instalación: exportar JSON desde la v0.3, mantener el mismo bundle principal, cerrar por completo la app y no desinstalarla. No instalar hasta verificar build y conocer limitación de firma.
- [x] XCTest de serialización, formatos y frescura de datos superados; pendiente instalación con firma real y aparición en galería de widgets.


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
