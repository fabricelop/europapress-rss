# TTActualidad — LEER PRIMERO ante una avería
**Edición:** 2026-10-29 · **Proyecto:** fabricelop/europapress-rss · **Documento vivo**  
**Manual extenso:** [TTActualidad-MEMORIA-OPERATIVA.md](TTActualidad-MEMORIA-OPERATIVA.md) · **Historial:** [TTActualidad-INCIDENTES-Y-DECISIONES.md](TTActualidad-INCIDENTES-Y-DECISIONES.md)

> **MENSAJE PARA PEGAR EN UN NUEVO CHAT:** «Estamos reparando TTActualidad NATIVA (iPhone SwiftUI y Windows Qt), no la web antigua. Lee primero docs/TTActualidad-LEER-PRIMERO.md y docs/TTActualidad-MEMORIA-OPERATIVA.md en fabricelop/europapress-rss/main, luego consulta el estado LIVE de GitHub, la rama iOS correcta y el eslabón fallido. Respeta los procesos de imágenes, el historial y las decisiones terminales. Diagnostica, corrige, verifica persistencia y actualiza esta memoria. Aquí está el error: [PEGAR SALIDA].»

> **Actualización prioritaria del usuario, 29/10/2026:** ya no se dan estrellas a los comentarios/remates y **sí se pueden pasar tendencias a noticias**. Verificado el botón iPhone «Enviar a TTiTTulares» y el handler `origin_trend` en main. Los JSON y párrafos de estrellas son restos históricos, no un paso actual que deba reactivarse. La prohibición antigua del puente no invalida la acción manual actual. Ver §§11–17 para evidencia, diferencias entre clientes y límites.

## Identidad: no confundirse de sistema
- **Fuente de verdad editorial:** archivos JSON de la rama **main** en GitHub. Releer siempre; el dato de una conversación anterior no es estado vivo.
- **iPhone:** app nativa SwiftUI en **ios/ttactualidad/**, compilación por .github/workflows/ttactualidad-ios.yml, IPA con PlumeImpactor. La familia **0.4.21 → 0.4.22** estaba en **feature/ttactualidad-ios-0.4.12-pistas** el 29/10; **NO modificar main suponiendo que es la versión instalada**. Comprobar rama, versión, build, última IPA y si se instaló antes de actuar.
- **Windows:** app nativa Qt **desktop/ttactualidad/TTActualidad_Moderno.pyw**, workflow ttactualidad-windows.yml, preferencia ZIP sin EXE; GitHub directo.
- **NO son estas apps:** antigua interfaz en docs/ttactualidad/index.html y pilot/ttactualidad-live/ desplegada en ttactualidad-decisions-pilot.fabricelop.workers.dev. Actualizar Cloudflare **NO** actualiza iPhone/Windows.
- **Backend distinto:** Cloudflare **tt-control.fabricelop.workers.dev** atiende comandos/ACK de los listeners editoriales e imágenes; esto NO convierte el Worker web antiguo en la app nativa. Telegram de noticias/tendencias como panel editorial **retirado**. **TTImages** sigue como canal independiente para imágenes.
- Preservar **FabCalendar, SeLoRecordamos, TTImages, URGENTE** y otros servicios. No reiniciar Chrome, alterar tokens, credenciales, sesiones, imagen activa ni borrar colas sin identificar sus propietarios.

## Localizar el eslabón en 60 segundos

| Síntoma | Primer archivo o prueba | Eslabón que revisar |
|---|---|---|
| No hay novedades/noticias nuevas | telegram/events.json, ttittulares/status.json, radar-no-d1.yml | Radar TTiTTulares, fuentes, agrupación y frescura |
| Noticias con 4+ fuentes no pasan a elaboración | telegram/editorial-processing.json, ttittulares/editorial-queue.json, ttittulares/auto_queue.py | Umbral, anti-duplicación y selección |
| Top 30 vacío/antiguo | trends/recent.json, ttendencias-refresh.yml | Captura y consenso de tendencias |
| Pendientes del Top 30 no pasan a elaboración | trends/requests.json, trends/editorial-queue.json, trends/auto_queue_new.py | Selección automática Top 30; excluir 31+ |
| «En elaboración» se acumula | Ambas colas + prompts editoriales + ramas control + logs locales | Solicitud ≠ envío real ≠ resultado persistido |
| Windows «Ready» pero no redacta | Get-ScheduledTaskInfo y logs de listeners en C:\TTiTTulares | Último resultado, Ejecutar.js, CDP 9223, ACK |
| «Target crashed» | ttittulares-mobile-trigger.log / ttendencias-mobile-trigger.log | ChatGPT/CDP 9223, pestañas, memoria, Ejecutar.js |
| Enviar tendencia a noticia falla | iPhone `sendTrendToNews`, dispatch `ttactualidad_manual_news_v1`, `pilot/submit_ttactualidad_manual.py` | Origen ID/revisión, recibo y PROCESSING en ambas colas de noticias; la tendencia se conserva |
| Texto elaborado pero no aparece en Listas | ttittulares/prepared.json / trends/telegram-manual-explained.json + requests.json | Outbox/apply, (ID,revision), commit a main |
| Noticia reaparece tras borrarla | ttittulares/decisions.json y pilot/ttactualidad-action-receipts.json | Decisión terminal + caché iOS/Windows |
| Tendencia reaparece tras borrarla | trends/mobile-decisions.json, requests.json, telegram-manual-explained.json | Tombstone/revisión y refresco de radar |
| Imagen IA no llega | image-runs (en rama control), listeners, ImageBridge, TTImageRelay | Job → envío ChatGPT Images → descarga PC → TTImages |
| Imagen en tarjeta con texto y banda inferior | Copiar GAG en SwiftUI/Qt y generador de prompt | No usar la antigua web; solo escena 16:9 sin texto |
| X se abrió pero no está publicada | pilot/ttactualidad-publication-events.json | Apertura de X no equivale a publicación; confirmar decisión |
| Móvil y Windows no coinciden | main JSON + recibos por request_id + cachés | Lectura fresca, terminales y acciones optimistas |

## Estado mínimo que debe adjuntarse a un incidente
1. **Proyecto:** TTiTTulares o TTendencias; **elemento:** event_id/id; **revision:** número; **fecha/hora Madrid**.
2. **Acción exacta:** preparar, reelaborar, copiar GAG, publicar, quitar, borrar, imagen, etc.; dispositivo iPhone/Windows/servidor.
3. **Resultado visible** y, si existe, **request_id, command_id o run_id**, sin compartir tokens.
4. **Archivos main relevantes** y estado JIT por el mismo (id,revision); **no basta un contador 0/0**, no basta HTTP 204, no basta «Ready» del Programador de tareas.
5. **Comprobación de persistencia:** noticia READY en prepared.json y no terminal; tendencia explained en **requests.json y telegram-manual-explained.json**, sin revisión posterior activa; imágenes fuera del bloqueo editorial.

## Diagnóstico Windows, SOLO LECTURA
Ejecutar en PowerShell normal; estas pruebas no modifican navegador ni colas:

~~~powershell
$base = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/'
$p = Join-Path $env:TEMP 'Diagnose-TT-Editorial-Local.ps1'
Invoke-WebRequest -UseBasicParsing -Uri ($base + 'Diagnose-TT-Editorial-Local.ps1') -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p

$p = Join-Path $env:TEMP 'TT-Editorial-Tab-Diagnose.js'
Invoke-WebRequest -UseBasicParsing -Uri ($base + 'TT-Editorial-Tab-Diagnose.js') -OutFile $p
node $p

$p = Join-Path $env:TEMP 'Diagnosticar-TTImages-Relay.ps1'
Invoke-WebRequest -UseBasicParsing -Uri ($base + 'Diagnosticar-TTImages-Relay.ps1') -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
~~~

Para memoria y pestañas: windows/Repair-TT-Chrome-Memory-Safe.ps1 **-InspectOnly**. Para identificar un runner que bloquea una recuperación: windows/Diagnose-TT-Active-Runner.ps1 (comprobar que su CI esté en verde). **No ejecutar Recover-TT-Chrome9223-Controlled.ps1 automáticamente.** Necesita administrador, identifica el perfil dedicado y debe ABORTAR si hay cualquier runner/imagen/conversación ocupada o incierta. No matar node.exe ni Chrome a ciegas.

## Reglas de oro
- El radar **capta y selecciona**; GitHub Actions **encola o solicita**, pero no investiga/redacta por sí solo. El editor de ChatGPT debe trabajar y **persistir en main**; un trigger y un ACK «launched» NO demuestran READY/explained.
- **TTiTTulares:** automático con **≥4 familias de fuentes generales independientes**, control de duplicados y hecho nuevo; manual puede investigar con menos. Elaboración factual + 2–3 hashtags específicos + **un** remate 🌶️, **≤256 caracteres**, sin generar imagen en la pasada.
- **TTendencias:** todas las pendientes del Top 30 entran automáticamente en elaboración; excluir puestos 31+; explicación caduca tras 48 h (sin destruir archivo); texto TT#N + hecho + hashtags + remate, **menos de 280 caracteres ponderados**; cierre coherente en **dos JSON**.
- **Imagen IA:** etapa independiente del texto. «Copiar GAG» debe producir **solo ilustración sin texto ni tarjeta inferior**; no dibujar 🌶️. Los puentes Chrome 9223 pueden hacer solo **launch_only**. La captura/envío real posterior pertenece a TTImageRelay, Chrome **9234**, PC → TTImages; no mandar imagen desde Actions/Telegram directo.
- **Estrellas retiradas:** no se piden ni se reactivan; los historiales y párrafos antiguos son contexto histórico. **Sí se permite enviar una tendencia a TTiTTulares por decisión del usuario**, con verificación posterior del hecho.
- **Acciones de usuario:** evento repository_dispatch → workflow → cambios en GitHub → **recibo por request_id** → lectura de main. No asumir éxito por HTTP 204. Borrados/publicadas/desestimadas son terminales; no resucitar registros por un JSON viejo. No publicar automáticamente en X.
- Los workflows retirados/no-op, instrucciones editoriales de Telegram anteriores al 17/10 y la web antigua son **HISTÓRICOS**. Ante conflicto, prevalece el flujo nativo real + los handlers productivos + estado main reciente.
- Tras corregir: probar con elemento real **(id,revision)**, comprobar las dos colas y el destino, los recibos, la imagen por separado, la concordancia iPhone/Windows y registrar el arreglo en la memoria larga y en el historial.

**Importante:** esta ficha es una referencia estructural, **no** un certificado de que toda la infraestructura funciona en este instante. Consultar GitHub y los logs actuales antes de cada diagnóstico.


## Agrupar Listas (30/10/2026)

Agrupar → dispatch `ttactualidad_group_listas_v1` → `pilot/listas_grouping.py` → request `task:group_listas` → runner editorial → `trends/listas-grouping-outbox/<job_id>.json` → workflow aplicador → ficha conjunta y originales marcadas **Agrupada en…**. **No cambiar las explicaciones originales.** Retirar agrupadas solo elimina originales cubiertas, no la conjunta ni suma publicaciones. Ver §18 del manual para estados/JIT/pruebas. Fuente iPhone nueva: `feature/ttactualidad-ios-0.4.23-agrupar-listas`, 0.4.23 build29; comprobar instalación.

**Corrección 30/10 tras prueba en iPhone:** originales agrupadas conservan **Quitar de Listas → Publicado / No publicado**. Solo Publicado suma esa original una vez; la conjunta no cambia. Fuente iPhone **0.4.24 build30**, rama `feature/ttactualidad-ios-0.4.24-quitar-agrupadas`. No confundirlo con Retirar agrupadas en bloque, que es limpieza sin publicación.


## Menú del icono del iPhone (30/10/2026)

Última fuente nativa: **0.4.25 build31**, rama `feature/ttactualidad-ios-0.4.25-menu-icono`, basada en 0.4.24. Tras abrir una vez la app, mantener pulsado el icono ofrece Noticias listas, Tendencias listas, En elaboración y Órdenes por confirmar. Cada acceso abre su destino y solicita una consulta. Contadores de la última lectura, con fecha/hora y aviso de datos parciales; no son información en tiempo real. Ver §20 del manual y `ios/ttactualidad/HOME-SCREEN-QUICK-ACTIONS.md` en esa rama.

El usuario confirmó finalmente que **Quitar de Listas de 0.4.24 funciona**; se descartó una nueva modificación del diálogo.


## Seguimiento de En elaboración (30/10/2026)

Última fuente iPhone: **0.4.26 build32**, rama `fix/ttactualidad-ios-0.4.26-seguimiento-editorial`, basada en 0.4.25. Corrige consultas periódicas cuando hay noticias/tendencias aceptadas en elaboración, comprobación de cola antes/después del botón, fallback de cola vacía y overlays de reelaboración ya READY. Ver §21. No confundir una pantalla sin refrescar con un trigger no registrado ni con una redacción no ejecutada.


**Nueva regla prioritaria del usuario, 30/10/2026:** toda pendiente del Top 30 (puestos 1–30) pasa automáticamente a En elaboración. Sustituye la restricción histórica de 11–30 manuales. Se conservan frescura de captura, cierres y explicaciones vigentes; el filtro Nuevas se elimina en iPhone 0.4.26. Ver §22.
