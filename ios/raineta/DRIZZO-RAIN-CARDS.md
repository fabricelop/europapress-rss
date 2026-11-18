# RainETA — estudio de las tarjetas de lluvia de Drizzo (18-11-2026)

## Alcance y fuentes examinadas

Referencia pública: [Drizzo en App Store España](https://apps.apple.com/es/app/drizzo-tiempo-y-radar-lluvia/id6812314038), notas de versiones 1.1.4–1.2.1 y su descripción de funciones. No se dispone de código de Drizzo ni de acceso directo a su ejecución en iPhone; el diseño de RainETA es una adaptación propia, no una reproducción visual exacta ni ingeniería inversa.

Drizzo documenta lluvia a intervalos de 15 minutos, radar histórico de dos horas y proyección por movimiento, tarjetas reordenables, widget «Antes de salir», widgets de radar en pantalla de inicio, comparación de modelos, diferenciación de «está lloviendo» y «posible lluvia» según evidencia, y avisos sobre pantalla bloqueada. No significa que sus pronósticos sean más precisos: requiere mediciones de acierto.

## Principios

1. **Respuesta antes que técnica.** La tarjeta indica si va a llover, el próximo cambio o un período probablemente seco; el detalle abre fuentes, intensidad y horizontes.
2. **Tarjetas modulares sin perder la información prioritaria.** El estado actual y ETA permanecen fijos; «Antes de salir», ventanas, Pulso, 3 h, radar, 24 h, 7 días y modelos se pueden ordenar y ocultar.
3. **Coherencia:** una sola fuente de decisiones por ámbito. El nuevo bloque «Antes de salir» reutiliza el pronóstico de minutos de RainStore y no inventa una ETA paralela.
4. **Fuentes honestas:** radar observado ≠ futuro, horas de modelos ≠ resolución minuto a minuto, nieve modelada ≠ radar, datos desconocidos ≠ seco.
5. **Ventanas secas prudentes:** hora con precipitación prevista inferior a 0,1 mm Y probabilidad inferior a 35%; no unir horas separadas o desconocidas; indicar que son modelos horarios.
6. **Actualización y permisos:** conservar GPS, Live Activity, fuentes, favoritos y preferencias de iPhone. No deducir que una Live Activity se actualiza indefinidamente con el proceso suspendido.

## Primera fase implementada en esta rama (candidata iOS 0.13.1)

| Tarjeta | Implementación | Fuente |
| --- | --- | --- |
| Estado y cuenta atrás | Siempre arriba, ya existente | RainStore + radar local utilizable / modelos |
| Antes de salir | Cuatro tramos de 15 min, estado + evidencia parcial | minuteForecast + RainVisualForecast.overview |
| Ventanas con poca lluvia | Hasta tres periodos en las próximas 12 h | RainSnapshot.hours, sin inferir huecos |
| Pulso de precipitación | Nativo de rama iOS 0.13.0, ahora reordenable | MinuteRainGraph |
| 3 h | Reordenable, conserva onda y detalle | ThreeHourRainView |
| Radar | Reordenable, modo ampliar intacto | RadarSection |
| 24 h | Reordenable, conserva precipitación y probabilidad | RainTwentyFourHourView |
| 7 días | Reordenable | RainWeekForecast |
| Modelos | Reordenable | RainMultiModelView |

Preferencias persistidas en AppStorage. Mantener distintas las tarjetas interiores y los widgets nativos de la pantalla de inicio de iOS: **estos últimos no están implementados aquí**.

## Siguientes fases, aún no implementadas ni validadas

- **Pantalla de inicio/bloqueo (WidgetKit):** contador / próxima lluvia, intensidad de 60 min, mapa reciente con caducidad, sin prometer actualización continua. Necesita target WidgetKit, App Group o transferencia de estado, entitlements compatibles y validación con la firma de instalación.
- **Avisos y Live Activity coherentes:** misma decisión meteorológica en tarjeta, actividad y notificación; revisar permisos y evitar duplicar avisos. Las push con app cerrada requieren infraestructura o funciones nativas y no se dan por implementadas.
- **Radar y modelos:** evaluar empíricamente continuidad de mosaicos, fiabilidad del horizonte y combinación con nowcast nacional. Mantener la rama avanzada del radar PWA/PR #98 separada; no reemplazar el motor sin backtests.
- **Panel de certeza:** acuerdo entre modelos, radar antiguo, ausencia de cobertura, precipitación posible. No convertir porcentajes de acuerdo en falsa confianza estadística.
- **Selección de actividades:** perfiles «caminar», «bicicleta» o «trayecto» solo si los datos de lluvia y tiempos permiten un consejo útil.
- **PWA RainETA:** adaptación posterior sin sobrescribir el radar experimental no fusionado ni confundir versión web con versión nativa.

## Comprobaciones obligatorias antes de entregar

- Build iOS (app + extensión de Live Activity), tests de simulador, IPA generado, revisión visual en iPhone.
- Contradicciones radar seco/modelo mojado; serie incompleta; comienzo y fin de lluvia; intensidad sin datos; nieve; franjas de 15 min; ventanas discontinuas; estado caducado; GPS, favoritos y radar al ordenar/ocultar tarjetas.
- Los tests de render y algoritmo no demuestran precisión meteorológica. No desplegar ni dar IPA por firmado si está generado sin firma.

## Apertura en el iPhone: la firma es otra cuestión

La IPA de GitHub se entrega **sin firmar** (CODE_SIGNING_ALLOWED=NO). Una instalación local con perfil gratuito Apple puede caducar a los 7 días, requiriendo firmar y reinstalar/renovar con la misma cuenta y bundle ID. **Conectar el iPhone a Sideloadly o su mecanismo de auto-renovación es pertinente; conectar la app a GitHub o ChatGPT no renueva la firma.**

Documentación: [Apple Developer — developer account](https://developer.apple.com/help/account/basics/about-your-developer-account/) y [Sideloadly](https://sideloadly.io/).
