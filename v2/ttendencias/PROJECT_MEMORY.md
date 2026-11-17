# Memoria operativa — TTActualidad V2 / retirada progresiva de V1
Actualización: 15 de noviembre de 2026.

## Nombres acordados
- **V2**: https://ttactualidad-v2-private-test.fabricelop.workers.dev/ (panel privado).
- **V1**: https://ttactualidad.rainyraven22.chatgpt.site/tendencias (site público).
- Repositorio: fabricelop/europapress-rss. Rama de trabajo V2: feature/ttactualidad-v2-clean; no confundir con main de los flujos V1.

## Política editorial V2
- La captura Top30 tiene proceso independiente; las explicaciones editoriales son trabajos de ChatGPT, separados de la generación de imágenes y sin publicación automática en X.
- RE reinicia explicación e imagen para la nueva revisión. Debe entrar con prioridad sobre nuevos Top30 incluso cuando la tendencia haya salido del ranking; nunca duplicar revisiones ya aplicadas.
- La cola canónica de editoriales está en v2/ttendencias/state/editorial-queue.json. Cloudflare D1 almacena acciones del editor. La sincronización RE de Windows consulta cada ~90 s; la GitHub Action de RE cada cinco minutos actúa como respaldo, con reintentos ante conflictos.
- RE-X solicitado por Fabrice: segundo botón junto a RE; recibe pistas del editor, obliga a intentar localizar y comprobar conversaciones/posts relevantes en X, y debe indicar claramente si X fue inaccesible. Las pistas no constituyen hechos y no autorizan acusaciones ni publicación automática. No introducir datos privados en el campo: las pistas viajan a la cola editorial del repositorio público.
- No mencionar «TTActualidad V2», IDs, revisiones ni metadatos del sistema en los párrafos periodísticos finales.

## Imágenes
- Las imágenes de revisiones RE/RE-X se generan mediante `image_worker_v2.py` igual que las de una tendencia nueva: `image_job_v2.proposed_job` emplea el `capture.answer` de la **revisión actual**, con un identificador nuevo, sin reutilizar la conversación editorial ni la imagen antigua. A partir del protocolo de envío 2, se prefiere el botón de enviar de ChatGPT sobre Enter, se conserva un diagnóstico sin contenido privado cuando no se crea chat, y cada revisión agotada en el protocolo anterior puede recibir un presupuesto acotado de intentos nuevos sin sobrescribir diarios antiguos. Las pruebas locales no sustituyen una prueba real en el perfil Windows del usuario.
- V2 privada puede mostrar imágenes sensibles.
- Interruptor de imagen pública: cuando está desactivado, oculta imagen solo en V1; un tema sensible se oculta por defecto salvo decisión editorial expresa.
- Botón de supresión total: la referencia queda bloqueada en V1 y V2; no afecta al texto de la tendencia.
- Cuando una imagen está oculta en V1, añadir junto a su icono IA el mismo icono con una X roja. Preferencias ancladas a tendencia y revisión.

## Instalación del consumidor Windows
- Tarea actual: TTActualidadV2-Editorial-Auto; perfiles, procesos y módulo V2 aislados de V1.
- El instalador histórico copia una vez los módulos: actualizar GitHub NO actualiza un consumidor ya instalado.
- Activador seguro: v2/ttendencias/Activate-V2-RE-Priority.ps1. Descarga una revisión fijada, prueba código, solicita salida cooperativa de un trabajo editorial en curso, respalda, instala y relanza. No mata Chrome ni V1.
- CI en Windows: workflow ttactualidad-v2-re-windows-check.yml. Superar la CI NO confirma activación en el ordenador del propietario. Estado: **ACTIVO en el Windows de Fabrice**. El 15/11/2026 comunicó salida real del activador: TT_V2_RE_STAGE_TESTS=OK, TT_V2_RE_PRIORITY_INSTALLED=YES, TT_V2_RE_PRIORITY_START_REQUESTED=YES, TT_V2_RE_PRIORITY_ACTIVE=YES; revisión instalada ac4cf6ac6cb3. Se respetó el trabajo en curso (WAITING_FOR_CURRENT_JOB=YES).

## Auditoría de tareas V1: aún sin desactivar
- ttendencias-refresh.yml: captura/cola histórica V1, cron cada 10 min.
- ttendencias-site-top30-sync.yml: proyección Top30 del antiguo Site, cron cada 5 min.
- ttendencias-editorial-apply.yml: aplica salida editorial V1, cron cada 5 min.
- ttendencias-editorial-reconcile.yml: reconcilia la cola V1, cron cada 15 min.
- ttactualidad-group-listas.yml y ttactualidad-listas-alerts.yml: compartidas con noticias/titulares, NO deshabilitar sin separar consumidores.
- La portada pública de tendencias V1 puede seguir ofreciendo datos V2; auditar cómo recibe el estado antes de retirar las tareas.
- Política de retirada: comprobar cero pendientes V1, cero dependencia real en envíos X/Telegram, compatibilidad de LISTAS, Site público y rutas/alertas. Solo entonces retirar cada cron V1 de manera recuperable, uno por uno.
- No confundir apagar captura y redacción V1 con quitar /tendencias del Site público: el usuario quiere conservar esa vista alimentada desde V2.

## Estado que no se debe exagerar
- Las pruebas Windows y RE-X posteriores a la ampliación pasaron en GitHub Actions (47 comprobaciones del panel privado).
- No afirmar «activado en Windows» sin lectura de salida de la tarea real.
- RE-X desplegado en el Worker privado el 15/11/2026: confirmado en producción por /health (build v2-re-x-20261115, configured=true) y /api/public-editorial-overrides (schema_version=1), ambos 200. La comprobación automática del workflow dio un falso negativo de verificación posterior al despliegue, pese a esas comprobaciones manuales correctas. La activación del consumidor Windows con prioridad RE/RE-X quedó confirmada por la salida real comunicada por Fabrice el 15/11/2026; resta comprobar el resultado de una solicitud RE-X concreta de extremo a extremo.
- V1 no ha sido apagada.

## Objetivo acordado: TTiTTulares / noticias en V2 — 15/11/2026 (análisis, sin activar)
- Fabrice quiere incorporar **noticias** a la web privada V2 en una página propia, junto a las tendencias existentes; conservar la captación multisource, agrupación y controles editoriales que funcionan en el radar de noticias anterior.
- La lógica fuente de referencia para estudiar y portar está en main: `telegram/radar_no_d1.py`, `telegram/content_filters.py`, `telegram/source_publication.py`, `telegram/source_telemetry.py`, `ttittulares/auto_queue.py`, `ttittulares/treated_news.py`, `ttittulares/apply_editorial_outbox.py` y los workflows de radar/redacción. **No usar main ni colas V1 como ejecutor o fallback de V2.** Crear estado, cola, decisiones y consumidores separados en `v2/ttittulares/`.
- Radar observado en código: 19 medios generales (16 familias editoriales independientes tras agrupar Atresmedia y Mediaset); 5 fuentes deportivas y 3 complementarias de descubrimiento. Umbral editorial normal: 4 familias generales corroborantes, no cuatro enlaces ni cuatro medios del mismo grupo. Registro de noticias 1–3 fuentes por 24 h, recuperación por fuente, exclusiones editoriales, título representativo, deduplicación histórica y reapertura solo ante novedad material.
- Flujo V2 deseado: captación/salud de fuentes → limpieza y agrupación por hecho → consenso y elegibilidad → cola V2 con `event_id + revision` → **un chat nuevo de ChatGPT para elaborar cada noticia** → validación y persistencia GitHub → **otro chat nuevo e independiente de ImageGen para una imagen por noticia/revisión** → validación del archivo y vinculación → ficha en la nueva página privada. Cada sesión de trabajo del consumidor se abre y se cierra al completar o fallar, con diario de ejecución; nunca depender del chat de texto al producir imagen.
- Texto e imagen deben seguir con **procesos, bloqueos, estados y reintentos separados**, como V2 tendencias, pero con selección de noticias elegibles en lugar del Top30. Un fallo de imagen no bloquea la noticia. Reevaluar una noticia crea nueva revisión sin duplicar la ya procesada y vuelve a habilitar la imagen de esa revisión.
- Web: página **Noticias** en el Worker privado V2 con las mismas garantías de autenticación, separando `En elaboración`, `Listas`, datos de fuentes/contraste y controles manuales de revisión, imagen, descartar y publicar en X. Nada de publicación automática ni importación automática del backlog V1.
- Estado al registrar esta nota: **solo se ha analizado** la arquitectura; la página de noticias, el radar aislado y los consumidores V2 para noticias aún no se han implementado. Activar por fases con pruebas de paridad, estados aislados, piloto controlado y confirmación del usuario.
- Estado de retirada V1 comunicado por Fabrice: tareas Windows de TTendencias Local y TTendencias-XContext deshabilitadas, STARTUP=NO, LISTENERS=0, BUSY_PROCESSES=0 y BUSY_TASKS=0; esto no demuestra que todos los cron GitHub, TTiTTulares u otros consumidores V1 estén apagados.
- Incidencia reciente V2 tendencias: en Maledon, Damian Jones, Ontiveros y otras, el texto mostrado en V2/X contenía encabezados editoriales en vez del contenido periodístico pese a que V1 era correcto. Se corrigió la extracción en el Worker privado de V2 (PR #437 informada en conversación anterior). Usar pruebas de regresión al implementar renderización de noticias y no propagar encabezados técnicos, IDs o etiquetas `LISTAS` al texto de X.

## 17 de noviembre de 2026 — perfiles Chrome desechables (fuente; instalación pendiente)
- Incidencia compartida: C: llegó a 0 GiB libres. Los perfiles por noticia de TTiTTulares V2 ocupaban 28,52 GiB. Fabrice eliminó 31 perfiles de noticias ya cerrados y recuperó 23,53 GiB; `AuthSeed`, imágenes originales y diarios siguen conservados. La corrección de perfiles de noticias se integró mediante PR #440.
- Preferencia explícita: ante fallo o reevaluación, abrir **otro chat desde cero**; no conservar perfiles Chrome para intentar recuperar chats antiguos. Nunca reenviar automáticamente una petición ambigua: mantener el diario de intento y las revisiones.
- Para **tendencias** el modo anterior reutilizaba `ChromeProfile` y `ChromeProfileImages`, más clones persistentes `-Parallel-##`. El nuevo `DisposableWorkerPool` mantiene los perfiles autenticados **como semillas intactas** y crea clones `-Job-##` para cada tendencia o imagen; los elimina tras el fin del proceso Python y la comprobación de que el Chrome exacto ya no está abierto, incluidos trabajos fallidos. Si Chrome sigue vivo, es imposible verificar los procesos, falla el borrado o aparece un perfil sin marcador, **no se elimina nada** y se bloquea la reutilización insegura. El número de rutas de trabajo está acotado por los workers (3 editorial y 2 imágenes por defecto); se comprueba un mínimo de 3 GiB libres antes de cada copia.
- Los clones persistentes `-Parallel-##` anteriores no se borran automáticamente durante la migración: una limpieza separada deberá verificar que ninguna tarea o Chrome los utiliza. Las tareas actuales de Windows NO se han parado ni actualizado desde este cambio GitHub.
- Se actualizaron ambos instaladores para incluir `chrome_profile_process_v2.py`, y dos tests de contratos preexistentes: el fake de GitHub suministra ahora SHA real del blob de la cola y la prueba de autoinicio acepta el lanzador oculto vigente por `wscript.exe`. Validación local: **196 tests V2** (3 omitidos), `compileall` y `git diff --check`, todos correctos. Falta instalar y ensayar el ciclo real en el Windows del usuario solo después de terminar los trabajos activos.


## 17 de noviembre de 2026 — generación de imágenes de Tendencias V2 sin avance visible
- La proyección pública `v2/ttendencias/state/web-top30.json`, capturada a las **21:01 UTC (22:01 hora peninsular)**, contiene 30 tendencias explicadas: **10 con imagen guardada, 20 sin imagen, 0 con generación en curso y 1 incidencia de imagen visible** (`#TEM17N`, revisión 3). Las otras 19 sin imagen muestran estado de reintento `unknown`; la proyección no permite distinguir por sí sola entre daemon detenido, fallo de lectura de cola o bloqueo por diarios locales. Es evidencia de falta de avance, no prueba del estado de la tarea Windows.
- La rama `feature/ttactualidad-v2-clean` incluye `image_daemon_v2.py`, `image_worker_v2.py` y `Install-V2-Images-Auto.ps1`. El daemon es independiente del editorial, escanea tendencias explicadas del Top30 con captura de la revisión vigente, usa dos trabajadores por defecto y un watchdog de **480 segundos** por chat; no reenvía a ciegas intentos con envío incierto o diarios incompatibles.
- `Install-V2-Editorial-Auto.ps1 -PilotOnly` deja expresamente la automatización de imágenes **sin cambios** (`TT_V2_IMAGE_AUTOMATION=INDEPENDENT_UNCHANGED`). El instalador específico `Install-V2-Images-Auto.ps1` prepara la instalación pero, sin `-EnableImages`, escribe `TT_V2_AUTO_IMAGES_ENABLED=NO` y deshabilita `TTActualidadV2-Images-Auto`; solo `-EnableImages` activa el consumidor. Por tanto, la instalación piloto editorial no equivale a actualizar ni reactivar el consumidor de imágenes.
- PR #469 y #470 están fusionadas: añaden `image_daemon_v2.py` al manifiesto del instalador piloto y hacen que el instalador descargue también su propia versión antes de probarla. **No activan** la tarea independiente de imágenes.
- Pendiente imprescindible: leer en Windows, sin modificar nada, el estado de la tarea `TTActualidadV2-Images-Auto`, el contenido de `auto-images-v2.enabled`, `image-daemon-status.json` y los últimos registros de `image-only-logs` / `image-parallel-logs`. Con ese diagnóstico se decidirá si basta con reactivar o si hay que actualizar/reparar el daemon. No tocar el consumidor editorial, V1, la publicación ni los diarios de intentos inciertos.
