# TTActualidad — guía rápida de contexto y averías

Referencia funcional: **30/10/2026**. Repositorio **fabricelop/europapress-rss**. Manual: [TTActualidad-MEMORIA-OPERATIVA.md](TTActualidad-MEMORIA-OPERATIVA.md). Antecedentes: [TTActualidad-INCIDENTES-Y-DECISIONES.md](TTActualidad-INCIDENTES-Y-DECISIONES.md).

Para empezar un chat de reparación:

> Estamos reparando TTActualidad nativa (iPhone SwiftUI y Windows Qt). Lee esta guía y la memoria operativa de fabricelop/europapress-rss/main, comprueba la rama que produjo el IPA instalado y relee el estado remoto del ID/revisión afectado. Localiza el primer eslabón sin resultado, corrige y verifica persistencia. Conserva decisiones, originales agrupadas e imágenes ya lanzadas. El síntoma actual es: [error, proyecto, ID/revisión, dispositivo y hora Madrid].

## Identidad y reglas

- **Datos editoriales:** main. **Triggers/ACK/jobs:** ramas control. **Ejecución del PC:** logs Windows. Una de esas pruebas no sustituye a las otras.
- **iPhone de esta entrega:** 0.4.28 build34, `feature/ttactualidad-ios-0.4.28-revision-y-grupos`. La fuente iOS de main puede ser anterior. Confirmar qué IPA está instalada antes de editar.
- **Windows:** `desktop/ttactualidad/TTActualidad_Moderno.pyw`, Qt; preferencia ZIP sin EXE. No confundir con la web anterior ni con Tkinter.
- **Todas las pendientes del Top30 entran automáticamente**. Fuera del ranking, el Radar solo encarga hasta dos borradores fuertes: sin puesto inventado, Listas, IA ni publicación; al entrar en Top30 se revalidan y reutilizan. No hay filtro Nuevas. Presupuesto externo0€; mismas fuentes y captura paralela de cuatro workers, sin aumentar frecuencia.
- **Revisión de novedades:** primero rojas (>24h), después amarillas (12–24h) y verdes (<12h). Máximo dos comprobaciones automáticas por ventana móvil de15min, máximo dos activas y una por origen/hora, con Top30 fresco. Las revisiones manuales tienen prioridad y no consumen ese cupo. Sin novedades conserva texto, fecha y color. Una actualización continuada usa «sigue siendo tendencia por…»; un episodio distinto requiere verificación y otra identidad.
- **Agrupación automática:** al cerrar texto y antes de pedir IA, comparar el mismo acontecimiento y cobertura ya publicada. Conservar originales, marcadas Agrupada en…; ambigüedad significa mantener separadas.
- **Agrupar manual:** seleccionar ≥2 tarjetas de Listas; solo se revisan esas. **Quitar de Listas** sigue permitiendo indicar publicada/no publicada. **Retirar agrupadas** conserva conjuntas y no suma publicación.
- **Publicación manual y contador:** solo published confirmado suma al ledger de24h móviles. Límite declarado por el usuario:51 publicaciones por cuenta en esa ventana. Abrir X, copiar o crear imágenes no suma.
- **Sin estrellas.** **Sí se puede enviar una tendencia a TTiTTulares** manualmente para investigar otra noticia con origen trazable.
- **Texto e imágenes separados:** READY/explained no espera foto ni IA. Una tendencia necesita grouping cleared del texto exacto para un nuevo job visual; covered no pide otra imagen.
- **Transporte IA:** image-runs → listener/ImageBridge CDP9223 launch_only → ChatGPT Images → relay CDP9234 → descarga PC → TTImages. Conservar FabCalendar, SeLoRecordamos, URGENTE, sesiones y credenciales.

## Encontrar la transición que falta

| Síntoma | Primera comprobación | Recorrido posterior |
|---|---|---|
| Noticias no entran | events, consenso≥4 familias, auto_queue/treated-stories | Elegibilidad y referencia concreta que bloquea |
| Tendencias pendientes no entran | recent fresco, requests/queue, auto_queue_new | Rango1–30, fuente fiable, terminal/revisión |
| Se acumula elaboración | Cola viva y trigger del mismo command_id | ACK → log listener → mensaje real → outbox → apply |
| Botón procesamiento parece inerte | Main fresco frente a pantalla | Si main tiene READY, consulta/overlay; si no, editor |
| Tendencia sin revisión | Fecha explicación, Top30, último checked_at | Color, cupo2/15min, máximo2 activas, prioridad de nuevas/manuales, job review_red, consumidor |
| Roja revisada sigue roja | red_review_outcome/checked_at | Sin novedades no renueva explained_at: es correcto |
| Agrupación atascada | grouping job/outbox/error | Candidatas snapshot, fuentes, revisiones y aplicación |
| Texto sin imagen | grouping_state/fingerprint/covered | Luego job → prompt → raster → relay → TTImages |
| Actualización ausente | maintenance-outbox y review_error | review_completed/created_id o stale por cambio concurrente |
| Borrada/publicada reaparece | decisions/mobile-decisions/recibo | ID/revisión/episodio y caché, sin destruir terminales |
| Tendencia→noticia falla | origin_trend y recibo manual-news | PROCESSING en ambas colas noticias; tendencia se conserva |
| Contador o menú difiere | publication-events y hora última lectura | Ventana móvil, canónico frente a provisional, órdenes locales |

## Archivos que resuelven el contexto

| Proceso | Archivos |
|---|---|
| Noticias | telegram/events.json; editorial-processing.json; ttittulares/editorial-queue.json, prepared.json, decisions.json |
| Tendencias | trends/recent.json, requests.json, editorial-queue.json, telegram-manual-explained.json, mobile-decisions.json |
| Mantenimiento | pilot/trend_maintenance.py, listas_grouping.py; trends/maintenance-outbox/, listas-grouping-outbox/ |
| Anticipación | trends/anticipation.py, anticipation-outbox/, anticipation-metrics.json; requests con anticipation_request |
| Aplicación y recibos | pilot/apply-ttactualidad-action.py; ttactualidad-action-receipts.json; ttactualidad-publication-events.json |
| Contratos | ttittulares/editorial-run-prompt.md; trends/editorial-run-prompt.md |
| Noticias texto final | TTITTULARES_OUTBOX_V1 en **issue164**; PR2 solo control/telemetría |
| Tendencias transporte/control | PR7, TTENDENCIAS_CHAT_OUTBOX_V1 y RUNTRACE canónico |
| PC | C:\TTiTTulares\ttittulares-mobile-trigger.log, ttendencias-mobile-trigger.log; Ejecutar.js local |
| IA | repair-ttittulares-listas.yml, repair-ttendencias-explicadas.yml; image-runs en control; ImageBridge; TTImageRelay |
| Cliente | EditorialStore.swift, GitHubEditor.swift, TTDashboard.swift, EditorialActionPanels.swift, HomeQuickActions.swift |

## Qué acredita una reparación

Releer el **mismo ID/revisión** en main y comprobar texto real, estado, cola y recibo, según el eslabón reparado. Para imágenes, distinguir lanzamiento, raster, descarga y entrega. Para UI, distinguir compilación/pruebas de instalación y uso físico. HTTP204, Windows Ready, ACK launched, Actions verde o contador0/0 no bastan por sí solos.

No reiniciar todo para probar. Si falta outbox, comprobar editor antes del aplicador. Si el texto ya está guardado, comprobar cliente antes de reenviar. Si una imagen ya fue lanzada, comprobar relay antes de regenerarla.

Al cambiar el sistema, **reescribir los apartados afectados de la memoria**, manteniendo una descripción coherente del funcionamiento vigente; registrar cambios y pruebas en el historial separado. La copia `TTActualidad-Memoria-Completa-2026-10-29.md` conserva nombre e identidad para adjuntarla desde cualquier chat.
