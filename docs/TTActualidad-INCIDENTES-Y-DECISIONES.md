# TTActualidad — registro de decisiones, incidentes y cambios
**Iniciado:** 2026-10-29 (Europe/Madrid). **Carácter:** histórico y cronología de hechos conocidos; NO estado vivo.  
**Lectura de emergencia:** [LEER PRIMERO](TTActualidad-LEER-PRIMERO.md) · **Arquitectura:** [MEMORIA OPERATIVA INTEGRAL](TTActualidad-MEMORIA-OPERATIVA.md).

> **Regla de trazabilidad:** agregar entrada cuando se modifica el comportamiento de un proceso, se detecta un fallo o se demuestra una reparación. Cada entrada debe distinguir: síntoma, causa verificada (o hipótesis), componente, versión/rama, acciones, evidencia, resultado y pendientes. No afirmar que algo está instalado o funciona solo porque un commit/CI exista. Evitar credenciales, IDs de usuario o contenido de sesiones.

## 1. Decisiones operativas que deben sobrevivir a futuros chats

### Interfaz y propiedad del sistema
- **TTActualidad es una app NATIVA en iPhone y Windows**, no la antigua web. iPhone es SwiftUI, código en ios/ttactualidad, con sus IPA en GitHub Actions; Windows es Qt, código desktop/ttactualidad/TTActualidad_Moderno.pyw, con ZIP Sin-EXE/EXE. Las interfaces consultan **GitHub main** y aplican decisiones autenticadas contra GitHub. Actualizar la vieja web de Cloudflare no corrige la app instalada.
- Las versiones fuente pueden divergir: a 29/10/2026, la serie **iOS 0.4.21→0.4.22** se trabajó en la rama feature/ttactualidad-ios-0.4.12-pistas. Ante cambios futuros, identificar commit que generó la IPA *realmente instalada*; main no es automáticamente esa versión.
- Los datos editoriales están en **fabricelop/europapress-rss/main**. Las **ramas control** de TTiTTulares y TTendencias transportan triggers/ACK e image-runs. No sustituir una por otra.
- Se retiró Telegram como **panel editorial** de noticias y tendencias hacia 16–17/10/2026. No confundir con **TTImages**, que permanece como destino específico de imágenes generado/capturado mediante PC.
- No tocar **SeLoRecordamos, FabCalendar, URGENTE** ni otros proyectos por reparar TTActualidad. Mantener la infraestructura sin volver a depender de Vercel o servicios de pago innecesarios.

### Reglas editoriales
- **Noticias automáticas:** mínimo **4 familias de fuentes generales independientes**, evidencia del mismo acontecimiento, anti-repetidos y frescura, con capacidad para detectar novedad material. Candidatos de una/dos fuentes permanecen en radar. Las solicitudes MANUALES pueden ordenar investigar aunque aún no lleguen a 4 fuentes, pero no autorizan inventar hechos.
- **Tendencias:** Top 10 entra automáticamente si no se ha explicado o ha vencido su explicación (~48 h). Puestos 11–30 **solo por decisión manual Preparar/reexplicar**. No seleccionar sin permiso «la siguiente 11–30» aunque una descripción histórica lo sugiera.
- **Salida noticia:** texto factual verificable, 2–3 hashtags específicos, un único remate 🌶️ al final; todo el tuit ≤256 caracteres; tweet.remate separado. **Salida tendencia:** TT#N + hecho verificado + 2–3 hashtags + remate si es adecuado, <280 caracteres ponderados X, explanation idéntica en requests y telegram-manual-explained para misma revisión.
- Texto se persiste primero en READY/Listas o explained/Explicadas **sin bloquearlo por imágenes**; la revisión de hechos y la barrera de revisión (ID, revision) son obligatorias. No declarar cola 0/0 hasta releer main y confirmar no hay solicitudes, revisiones ni reexplicaciones activas.
- Solo el usuario publica, desestima o quita de Listas. **No inferir publicación por abrir X**, ni borrar una tarjeta recibida por considerarla duplicado si ya está bajo control del usuario. Las decisiones finales deben impedir reapariciones.

### Imágenes
- La IA es un **proceso separado**: generación solicitada en image-runs de rama control → listener de Windows → bridge Chrome 9223 en modo **launch_only** → ChatGPT Images → captura/descarga local TTImageRelay, Chrome 9234 → bot **TTImages**, desde el PC. No usar los workflows directos de Telegram retirados.
- **Copiar GAG** de la app nativa debe ofrecer imagen 16:9 con ilustración rica, una sola idea visual, **sin texto, titular, remate, hashtags ni franja inferior de noticia**; el texto factual es *solo contexto* y el emoji 🌶️ no se dibuja. En tragedias, ilustración seria y sin banalización.
- No duplicar imágenes si hay un job activo o una captura pendiente. Un ACK launched no prueba que se haya capturado una imagen. Tratar las fotografías de archivo como un canal diferente, sujeto a derechos.

### Fiabilidad y seguridad
- Una tarea Windows con estado **Ready** y un run de GitHub en verde **no demuestra** que el editor haya escrito en Listas. Distinguir trigger, ACK, envío real del mensaje de ChatGPT, outbox, apply y verificación en main.
- Antes de reparar Chrome, verificar exactamente qué proceso/tabs están ocupados. No matar indiscriminadamente Node, Chrome ni los puentes de imagen, ni eliminar locks de trabajo. Con incertidumbre, **abort** y preservar imágenes/sesiones/colas.
- iOS y Windows tienen credenciales y cachés propias. **GitHub main + recibos por request_id** resuelven divergencias. Nunca sobrescribir decisiones terminales con datos descargados parcialmente.

## 2. Cronología de incidentes y reparaciones

### Octubre 2026 — transición a una arquitectura de control directo
**Antecedente:** coexistieron durante el desarrollo Telegram editorial, paneles web, Cloudflare Workers, automatización Windows, ChatGPT y, finalmente, aplicaciones nativas. Varios scripts y README describen estados anteriores.  
**Decisión:** desde mediados de octubre, dar prioridad a la persistencia verificable de texto en GitHub y a TTActualidad como interfaz; mantener el canal TTImages para imágenes, independientemente del texto.  
**Acción para futuras reparaciones:** comprobar si un workflow está **realmente activo** o es un no-op histórico. Revisar primero ttittulares/editorial-run-prompt.md y trends/editorial-run-prompt.md, no ejecutar instrucciones de Telegram que quedaron obsoletas.

### 6–9 de octubre — estabilidad de infraestructura y separación de Vercel
**Antecedente:** problemas de imágenes y automatizaciones; cuenta Vercel pausada por CPU, sin intención de pasar a Pro. Se migraron funciones de TTendencias y TTiTTulares a Cloudflare Workers.  
**Criterio persistente:** alta prioridad para TTendencias, FabCalendar y SeLoRecordamos; no provocar gastos/reintentos masivos. Evitar usar la antigua web/Worker como referencia de la aplicación nativa.  
**Pendiente histórico que no se debe reabrir sin evidencia:** las funciones de publicación, desestimar y borrado de la etapa Telegram tuvieron bugs separados de las apps nativas.

### 15–17 de octubre — cierre editorial y política de imágenes
**Síntoma histórico:** el texto editorial dependía de entrega Telegram o imagen; entradas quedaban pendientes al no completar imagen.  
**Decisión:** READY de TTiTTulares y explained de TTendencias dependen de **texto + remate + persistencia confirmada**, no de ImageGen, archivo ni Telegram. La elaboración oficial no debe llamar directamente a ImageGen.  
**Implementación conceptual:** workflows de reparación visual encolan la IA **después** de READY/explained. El PC y TTImageRelay hacen generación/descarga/envío en procesos distintos. Telegram editorial desactivado como panel.  
**Verificación:** comparar JSON de Listas/Explicadas antes de mirar image-runs. Nunca bloquear cierre por IA.

### Octubre 2026 — duplicados, revisiones y sincronización
**Síntoma:** tarjetas que reaparecen después de quitarlas o se ven en iPhone pero no en Windows.  
**Causa habitual identificada:** lecturas GitHub parciales/desactualizadas, acciones optimistas sin receipt y carreras entre revisión/decisión terminal.  
**Ruta correcta:** acción con request_id → GitHub repository_dispatch → workflow → pilot/ttactualidad-action-receipts.json + decisiones → main fresco → refrescar clientes. Un HTTP 204 es aceptación, no éxito.  
**Política:** published/deleted/dismissed son tombstones y no deben perderse. No vaciar listas o borrar por similitud si una tarjeta tiene decisión manual propia.

### 29/10/2026 — «Copiar GAG» confundido con la web antigua
**Síntoma:** el botón copiaba prompts que producían imágenes tipo tarjeta de noticia, con un enorme pie de texto, en lugar de gags visuales sin texto.  
**Primer intento INCORRECTO:** se editó HTML de la antigua TTActualidad web y se desplegó ttactualidad-decisions-pilot en Cloudflare. El despliegue era válido, pero **NO actualizaba la app nativa**.  
**Corrección de arquitectura:** localizar **ios/ttactualidad/TTActualidad/EditorialActionPanels.swift** en la rama feature que contenía la IPA real y **desktop/ttactualidad/TTActualidad_Moderno.pyw**; actualizar el prompt **GAG_VISUAL_NATIVE_V2** en AMBOS.  
**Pruebas:** GitHub Actions compiló **IPA iOS 0.4.22** y distribuciones Windows. **No confundir compilado con instalado en los dispositivos**.  
**Regla:** ante un fallo de botón, revisar el código de app que lo implementa (SwiftUI/Qt), no el HTML legacy.

### 29/10/2026 — «En elaboración» atascado y cron Windows aparentemente activo
**Síntoma:** varias noticias en **PROCESSING** y tendencias en **preparing**; el Programador de Windows mostraba TTendencias Local/TTiTTulares Local «Ready» cada 15 min, pero no aparecían nuevas Listas.  
**Prueba local 21:38 Madrid:** ambas tareas tenían **LastTaskResult=1**, listeners dedicados en ejecución, Node instalado, CDP 9223 respondía. Logs indicaban **ERROR: Target crashed** para titulares y tendencias. TTiTTulares repetía el mismo lanzamiento fallido aproximadamente cada **15–20 segundos**; TTendencias empleaba backoff de **10 minutos**.  
**Causa inmediata:** **falló el envío real de ChatGPT por Ejecutar.js/target CDP**. No era prueba de un problema de JSON/Listas. No se verificó una causa raíz única de los crashes.  
**Corrección parcial:** se añadió **backoff de diez minutos** al listener TTiTTulares para evitar tormentas de reintentos; se conservan órdenes e imágenes. Ruta windows/TTiTTularesDedicatedListener.ps1.  
**Diagnóstico adicional 21:44:** script Node contó 4 páginas CDP, 3 jobs de pestañas monitorizadas (2 sin mensajes, 1 busy). Script PowerShell de memoria contaba erróneamente **0 páginas**, corregido después. Windows registró varios **Resource-Exhaustion-Detector event 2004** alrededor de 19:40–19:57; a 21:44 el compromiso era **22,59 GB / 81,71 GB (27,6%)**. **No afirmar** que existía agotamiento de memoria en el momento preciso del último target crash.  
**Reconstrucción controlada:** windows/Recover-TT-Chrome9223-Controlled.ps1 endurecido para comprobar identidad de Chrome dedicado, respaldo de sesión, runner activo, tabs ocupadas/drafts y estados inciertos antes de reiniciar; sin afectar a navegador habitual ni Chrome 9234.  
**Prueba real 21:52:** recuperación **se detuvo sin cambios** con **RECOVERY_BLOCKED active editorial/image processes=1**. Es protección correcta; no significa que el proceso estuviera colgado.  
**Hecho paralelo:** esas 12 elaboraciones iniciales acabaron en estados cerrados en GitHub mediante el trabajo editorial ejecutado por otros mecanismos; ello **no probaba que Ejecutar.js estuviese reparado**. Nuevos elementos pueden entrar en cola continuamente.  
**Estado no probado:** reparación completa y sostenida de Chrome/launcher, versión exacta de Ejecutar.js, si la siguiente orden fue elaborada solo por Windows. Hay que comprobar cuando vuelva a fallar.  
**Herramientas de diagnóstico:** windows/Diagnose-TT-Editorial-Local.ps1, TT-Editorial-Tab-Diagnose.js, Repair-TT-Chrome-Memory-Safe.ps1 -InspectOnly, Diagnose-TT-Active-Runner.ps1. Revisar su CI antes de instalar. **NO** forzar Chrome 9223 si hay imagen o runner activo.

### 29/10/2026 — tarea ChatGPT «Elaboración editorial TT» desactivada
**Observación:** la tarea recurrente dentro de ChatGPT figuraba **disabled**, último run 28/10.  
**Implicación:** no se puede suponer que una petición GitHub la reactivará. Windows tiene sus propias tareas y listeners; revisar cuál está autorizado y consumiendo realmente triggers.  
**Regla:** no reactivar/reprogramar una tarea desactivada sin verificar que sigue deseándose.

### 29/10/2026 — memoria operacional formalizada
**Problema:** cada fallo exigía reconstruir arquitectura y cronología desde muchos chats.  
**Medida:** creación de tres ficheros canónicos en docs/: LEER-PRIMERO, MEMORIA-OPERATIVA e INCIDENTES-Y-DECISIONES.  
**Objetivo:** diagnóstico por primera transición sin salida, sin equivocarse de app o perder pruebas de la reparación.

## 3. Plantilla para cada incidente nuevo

Copiar esta ficha al FINAL del documento por cada avería/resolución:

~~~markdown
### [AAAA-MM-DD HH:MM Madrid] — [eslabón + síntoma]
- **Proyecto, dispositivo, revisión/branch:** [TTiTTulares/TTendencias, iOS/Windows/backend, versión].
- **ID/revisión del item:** [event_id/id, revision]; **request_id/command_id/run_id:** [si existe].
- **Comportamiento observado y evidencia:** [logs, estado, URLs de GitHub Actions, horas].
- **Primera transición que falló:** [fuente → radar → selección → trigger → listener → chat → outbox → apply → Listas → imagen → entrega → UI].
- **Causa raíz:** [probada con evidencia / hipótesis por confirmar].
- **Cambio aplicado:** [rutas concretas, commit, backup/rollback, tests].
- **Verificación:** [ID exacto persistido en main, receipt, cola, imagen/destino separados].
- **Resultado:** [completado / parcial / bloqueado con motivo].
- **Pendientes y precauciones:** [qué todavía NO se ha probado].
- **Actualizaciones del manual:** [secciones afectadas].
~~~

## 4. Mantenimiento de la memoria

1. **Cada cambio en ruta o estado:** actualizar memoria operativa y la tabla rápida. Registrar commit y por qué no afecta al resto.
2. **Cada fallo y recuperación:** completar plantilla con evidencia, primer eslabón roto y confirmación de salida. No usar «resuelto» si solo se ha cambiado código o hay un artifact sin instalar.
3. **Cada actualización de app:** anotar rama, versión, build, run y confirmar qué versión está realmente instalada en iPhone y Windows.
4. **Cada modificación de automatizaciones:** actualizar horarios reales, tarea, consumidor y método para saber que acabó. Distinguir UTC de Europe/Madrid.
5. **Cada modificación de imagen:** documentar separación **ImageBridge 9223/ChatGPT Images** y **TTImageRelay 9234/TTImages**, idempotencia y salida raster real.
6. **Antes de usar una receta:** leer los archivos actuales y cualquier nuevo cambio que sucediera después del presente documento. No dar por hecho que la memoria es un snapshot en tiempo real.


## 5. Revisión de memoria y correcciones del usuario — 29/10/2026

- **Problema:** las memorias iniciales y algunos contratos mezclaban flujos heredados con funciones nativas vigentes. La investigación inicialmente reprodujo dos errores al dar prioridad al texto del contrato sobre el flujo real.
- **Corrección expresa del usuario:** ya no se dan estrellas a comentarios/remates; sí se pueden pasar tendencias a noticias. Estas instrucciones prevalecen sobre la prohibición/valoraciones de párrafos antiguos.
- **Verificación de estrellas:** sin controles de puntuación encontrados en las 16 fuentes Swift de `dedcaabf1134be45b16efe482cf67ceec67e4998` ni en la UI Qt contrastada. Los ficheros ratings y párrafos antiguos permanecen; no se ha demostrado un sustituto. Se documentan como históricos, no se reactivan.
- **Verificación del puente:** botón «Enviar a TTiTTulares», `sendTrendToNews()` y `GitHubEditor.addNews(originTrend:)`; main recibe `ttactualidad_manual_news_v1` y `pilot/submit_ttactualidad_manual.py` valida origen y encola PROCESSING r1 con trazabilidad y recibo. La tendencia original se conserva. Ocho tests sintéticos existentes ejecutados correctamente; sin envío real ni publicación.
- **Diferencia de Windows:** el Qt main consultado carece del botón/payload específico. Esto no niega la función iPhone/backend ni demuestra paridad; no se modificó código de producto.
- **Otros ajustes documentados:** transporte nuevo de noticias exclusivamente #164, Tremending lectura y seen_urls, límites 24 h/48 h/180 días, imagen launch_only frente a captura/entrega, derechos no verificados de archivo, vigilancia y límites, avisos ntfy y divergencia de operaciones múltiples entre ramas.
- **Corte:** main `0fb2cfbcbd1d1aabb820413b01b6dc451c7aaf20` (29/10 22:32:26 Madrid); iPhone fuente 0.4.22 build 28, instalación no verificada. Conversaciones recuperadas selectivamente; no se afirma exportación exhaustiva ni acceso al PC físico.
- **Pendiente separado:** alinear, si se solicita, los contratos productivos que aún hablan de estrellas o prohíben el puente manual. Esta tarea mantiene operativos y sin cambios prompts, automatizaciones, apps y datos editoriales.


## 6. 30/10/2026 — Agrupar Listas sin cambiar explicaciones originales

**Decisión:** nueva ficha conjunta; originales conservadas con estado visual de cobertura y retirada rápida. La aclaración del usuario sustituye la idea inicial de copiar la explicación conjunta a todas.

**Componentes:** `pilot/listas_grouping.py`, `ttactualidad-group-listas.yml`, cola/contrato de tendencias, protección de publicación en `apply-ttactualidad-action.py`, UI Qt y SwiftUI 0.4.23 build29. No publicar, borrar ni agrupar datos reales solo por instalar el cambio: la revisión se solicita con el botón.

**Validación:** pruebas sintéticas de persistencia y carreras; UI Windows y preflight iPhone. Distinguir solicitud aplicada, revisión editorial completada, build compilado e instalación en dispositivo. Ruta y diagnóstico detallados en §18 del manual.


## 7. 30/10/2026 — restaurar Publicado/No publicado al retirar una original agrupada

**Prueba del usuario:** agrupación correcta; captura de iPhone 0.4.23 con Star Trek AGRUPADA y botón Retirar agrupada sin la elección habitual. **Causa:** la UI suprimía Publicado y el backend rechazaba ese estado sobre cubiertas. Esa restricción no fue solicitada y se retira.

**Cambio:** Quitar de Listas ofrece Publicado y No publicado en iPhone 0.4.24 build30 y Windows. La decisión se aplica solo al ID/revisión de esa original, con ledger idempotente y sin modificar conjunta, hermanas ni textos. Retirar agrupadas en bloque sigue sin sumar publicaciones. La confirmación del usuario demuestra uso real de la agrupación; no prueba todavía la instalación de la corrección 0.4.24.

**Validación:** tests del handler completo con ambos estados, una sola publicación al reintentar, ninguna en No, conjunta inmutable y UI con confirmación restaurada. Consultar §19 del manual. No se modificaron decisiones editoriales reales en esta reparación.


## 8. 30/10/2026 — accesos al mantener pulsado el icono

El usuario solicitó un menú útil en el icono del iPhone. Se implementan cuatro accesos nativos en 0.4.25 build31: Noticias listas, Tendencias listas, En elaboración y Órdenes por confirmar. Los títulos incorporan contadores de la última lectura y los subtítulos su fecha/hora; los datos parciales se identifican. El menú abre el destino y consulta el estado; no ejecuta acciones editoriales por sí mismo.

La fuente es `feature/ttactualidad-ios-0.4.25-menu-icono`, basada en la 0.4.24 real, sin sustituirla por el iOS antiguo de main. Ver §20 de la memoria para delegados, router, almacenamiento y diagnóstico. La validación automática comprende siete pruebas nativas de lógica en iOS Simulator y compilación del IPA; instalación y gesto en el iPhone requieren comprobación del usuario.

**Cierre de la incidencia anterior:** el usuario confirmó que Quitar de Listas funciona en 0.4.24; no se aplicó otra modificación al diálogo.


## 9. 30/10/2026 — seguimiento detenido de noticias en elaboración

El usuario veía ocho noticias y no percibía efecto del botón. La petición de iPhone sí estaba persistida (`tt-ios-1793362478410-b1491681`). Mientras se revisaba, el editor concurrente cerró siete noticias entre 13:23 y 13:25 Madrid, y la cola/resumen quedaron a cero a las 13:27. No se generaron esas noticias desde esta reparación.

En 0.4.25 las noticias aceptadas en elaboración no activaban por sí solas el sondeo; el botón tampoco leía el estado antes/después. Había además fallback de una cola vacía a un resumen antiguo y overlays que podían esperar una fase intermedia ya superada. 0.4.26 build32 corrige esos cuatro puntos, consulta cada minuto mientras corresponda y no declara cola vacía ante una lectura fallida. Conserva el menú del icono y el resto de funciones.

Fuente: `fix/ttactualidad-ios-0.4.26-seguimiento-editorial`. Ocho regresiones nativas nuevas más siete existentes; compilación de app y Live Activity. Ver §21 del manual y `ios/ttactualidad/EDITORIAL-PROGRESS.md` en la rama. No se modificaron Chrome, listeners, automatizaciones, imágenes ni decisiones editoriales reales.


## 10. 30/10/2026 — todas las pendientes del Top 30 pasan automáticamente a elaboración

El usuario amplió explícitamente la selección automática de puestos 1–10 a 1–30 y pidió quitar Nuevas. Se actualizan selector, conservación de cola, workflow y contrato editorial en main; se mantienen cierres, explicaciones vigentes, capturas fiables y episodios independientes. El iPhone 0.4.26 elimina Nuevas y la etiqueta Preparación manual de 11–30. Pruebas de selector/idempotencia/terminales/caducidad/grupos y 13 pruebas de Agrupar correctas. Ver §22.


**Verificación en producción, 30/10/2026 a las 13:45 Madrid:** el workflow https://github.com/fabricelop/europapress-rss/actions/runs/41057441931 terminó correctamente y persistió cinco nuevas solicitudes `preparing`: Calvario (#14, `1d009d35b4f9`), #Mañaneros30O (#17, `f1fe0e54a4d5`), Transportes (#19, `524f7ecb7b46`), Madrid-Sevilla (#24, `a7db60a725f4`) y Alta Velocidad (#28, `281a5360a665`). El runner recibió la solicitud `tr-1793364317490-manual`. Esto confirma encolado y petición, no explicaciones terminadas. El IPA final 0.4.26 build32 corresponde a `6ec79d5e3d28b1cef8dda200498b50790e39334f`; https://github.com/fabricelop/europapress-rss/actions/runs/41057142681 superó 15 pruebas nativas y compiló app + Live Activity. Backend: tests Top30 y 13 pruebas de agrupación correctas. No se ha probado el IPA físicamente en el iPhone durante esta reparación.
