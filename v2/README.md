# TTActualidad V2 — construcción aislada

> **Objetivo prioritario actual (13/11/2026):** [Primer hito funcional de TTActualidad V2](ttendencias/PRIMER_HITO.md) — Top 30 cada 15 minutos, web PC/móvil con estados y explicación, y un Chrome/chat independiente por tendencia, que se cierra tras persistir. Reutilizar las soluciones probadas de V1. No activar publicación.
>
> **Realizado:** proyección web de 30 puestos (`ttendencias/web_top30_v2.py`, `ttendencias/state/web-top30.json`), primera interfaz `ttendencias/web/index.html` y actualización desde GitHub. **Falta:** despliegue HTTPS de la interfaz, consumidor editorial autónomo y ensayo completo de estados en navegador.

**Rama:** `feature/ttactualidad-v2-clean`. **Estado:** paso 1 validado en vivo (Actions #43320096517); paso 2B configurado con GetDayTrends como fuente única, pendiente de validar en Actions.

## Reglas de aislamiento
- Producción `main`, workflows, Windows, Cloudflare, app, Site y publicaciones: **sin cambios**.
- Código nuevo exclusivamente en `v2/`; no se utilizan las colas, tokens ni decisiones de producción para escribir.
- Las Actions existentes programadas solo ejecutan en la rama por defecto; el nuevo CI V2 solo verifica código, sin escribir y sin cron.
- No se ejecuta `trends/update_trends.py` completo: se **reutilizan las funciones de interpretación** actuales, pero el nuevo capturador no modifica `trends/recent.json` ni `trends/editorial-queue.json`.

## Etapas
1. **Captura Top30 España:** `v2/ttendencias/capture_top30.py`; obtiene HTML de GetDayTrends y exige treinta posiciones únicas antes de entregar un JSON. Distingue `observed_at` (hora de nuestra lectura) de una observación original en X, que **no está verificada**.
2. **Diagnóstico de frescura:** `v2/ttendencias/assess_freshness.py` diferencia la edad de nuestra captura de la frescura original de X. No declara verificada una tendencia por HTTP 200, por cambio de lista ni por fecha local reciente. **Decisión del usuario (12/11/2026):** GetDayTrends será la única fuente por ahora. Si la consulta en vivo devuelve 30 posiciones válidas de España y la captura tiene hasta 20 minutos, `eligible_for_editorial=true` para el FUTURO paso 3 (todavía no conectado). No se afirma verificación directa por X. La comparación con otra fuente queda opcional, no bloqueante.
3. **Movimientos e historial V2:** `v2/ttendencias/detect_changes.py` detecta altas, salidas, cambios de puesto y regresos; asigna un `trend_id` permanente y determinista por término normalizado, sin usar fechas ni posiciones. Un regreso tras más de 24 horas fuera crea un episodio de revisión bajo el mismo ID; si la ausencia es de 24 horas o menos, conserva el episodio. El historial de identidades no se poda por antigüedad. Primera lectura = línea base sin 30 falsas noticias. No se incorpora a la cola editorial de producción.
4. **Cola editorial aislada:** `v2/ttendencias/editorial_queue.py` organiza un registro permanente por `trend_id` con `revision`, `status`, `episode_token`, motivo y copia de la explicación previa. Las tendencias nuevas sin explicación entran una sola vez en `pending`; una reentrada tras más de 24 h puede pasar de una revisión terminada a `review_pending` sin cambiar ID ni perder el texto anterior. Cambios de explicación solo por una señal editorial explícita, nunca por variación de puesto. El módulo no investiga, redacta, llama a ChatGPT ni publica.
5. **Reserva editorial (5A):** `v2/ttendencias/editorial_consumer.py` permite simular la reclamación de una tendencia pendiente por un consumidor concreto; crea token, revisión, caducidad de 15 minutos, reintentos (máximo 3) y cierre `ready` solo con token vigente y texto no vacío. **No hay conector ChatGPT ni consumidor en ejecución**. La reserva no se guarda ni se activa desde CI; únicamente se prueba en memoria.
6. Investigación real, imágenes, decisiones, publicación y migración — **pendiente**.

## Probar (sin efectos laterales)
```sh
python3 -m unittest discover -s v2/ttendencias -p 'test_*.py' -v
python3 -m v2.ttendencias.capture_top30
```
El segundo comando realiza una **consulta de lectura** en vivo y muestra un snapshot en stdout. No genera commits ni modifica producción. La opción `--output v2/ttendencias/state/capture.json` permite guardar localmente un resultado aislado para comparación, sin envío ni automatización.

## Paso 3: contrato de estados
- Recibe solamente la captura GetDayTrends V2 aceptada en el paso 2.
- Exige tiempos monótonos, no mezcla capturas de una misma hora con contenidos distintos y es idempotente.
- `baseline` es inicialización; `entry`, `exit`, `up`, `down`, `short_return`, `reentry` son transiciones, no solicitudes editoriales.
- **Regla de identidad (usuario):** cada término mantiene SIEMPRE el mismo `trend_id` aunque desaparezca meses; `episode_token` es solo una marca técnica de revisión, nunca un ID de ficha. Una reentrada tras **más de 24 horas fuera** genera `reexplain_candidate:true` sobre ese mismo ID, sin explicar automáticamente. Una causa nueva o una explicación materialmente cambiada también podrá activar revisión en la futura etapa editorial, aunque la tendencia no haya salido. No hay reexplicaciones por cambiar de puesto ni por tener 24 horas de antigüedad sin salida observada.
- Datos locales solo en `v2/ttendencias/state/` o artefactos temporales de CI. Una sola captura prueba el arranque; para validar cambios reales hacen falta snapshots sucesivos.

## Paso 2: condiciones de aceptación
- Informar `capture_age_minutes` y marcar una captura con más de 20 minutos como `capture_expired`.
- **Nunca** confundir `observed_at` con la fecha de observación de X: `source_observed_at=null` hasta evidencia independiente.
- Guardar `freshness-report.json` solo como artefacto temporal de Actions, sin commits ni modificaciones de main.
- Aceptar GetDayTrends como única fuente según decisión del usuario, sin mostrar validación de X que no existe.
- No abrir cola editorial ni provocar efectos de producción.

## Puerta de salida del paso 1
Pruebas unitarias aprobadas, lectura en vivo con 30 posiciones y metadatos verificables. Hasta entonces no se considera E2E validado. No sustituir la fuente ni afirmar correspondencia directa con X.

## Persistencia del historial entre capturas (paso 3)
- El workflow de prueba V2 guarda exclusivamente `v2/ttendencias/state/history.json` **en la rama `feature/ttactualidad-v2-clean`** tras una captura válida.
- Un `git fetch` obtiene el último historial antes de cada cálculo. El proceso acepta solo capturas posteriores, conserva los `trend_id` estables y vuelve a calcular si hay conflicto de escritura.
- El workflow solo responde a cambios V2 en la rama de pruebas; no hay cron productivo, órdenes editoriales, publicaciones ni cambios en `main`.
- Cada ejecución crea un artefacto temporal y verifica los cambios. Los commits automáticos hechos con el token de GitHub no disparan otra ejecución de este workflow.
- La primera ejecución persistida establece 30 identidades; la siguiente debe reutilizarlas en otra captura y almacenar entradas y salidas reales si las hay.

## Paso 4: cola editorial V2 (sin efectos)
- Archivo **aislado**: `v2/ttendencias/state/editorial-queue.json`, guardado en el mismo commit de la captura/historial de la rama V2.
- `items` es un diccionario indexado exclusivamente por `trend_id` permanente, no por `episode_token` ni rango; una sola fila por tendencia.
- Estados reservados: `pending`, `review_pending`, `in_progress`, `ready`, `published`, `dismissed`, `cancelled` (solo los dos primeros los crea automáticamente este paso).
- Primer arranque V2: se prepara como `pending` una explicación por cada una de las 30 tendencias si aún no existe entrada editorial V2. No se ejecuta nada ni se envían solicitudes.
- Salir del Top30 no elimina ni duplica tareas. Regresar antes de 24 horas no genera revisión; una reentrada >24 horas marca `review_pending` solo si el estado anterior estaba terminado.
- Una explicación cambia solo si una futura fase editorial emite una señal `changed_explanations` validada: **no se presupone** que el texto haya cambiado por entrar o salir del ranking.
- Las fases 5+ implementarán la investigación, cierre transaccional y decisión del usuario. Hasta entonces `effects_enabled=false`; **no se escribe en las colas reales**.

## Paso 5A — contrato de reserva editorial (todavía sin procesamiento real)
- `pending` es espera, `in_progress` exige una reserva por `worker_id` y token; el controlador no debe marcar trabajo como ejecutado solo por encolarlo.
- `claim` respeta una capacidad máxima global (por ahora 1 en el ejemplo), `recover` recupera reservas vencidas tras 15 minutos, hasta 3 intentos. Una reserva agotada queda `cancelled` con motivo explícito, para intervención/revisión posterior.
- `complete` comprueba `trend_id`, `revision`, token vigente y texto no vacío antes de pasar a `ready`; el resultado tardío no puede cerrar una revisión equivocada.
- **Solo pruebas/simulación:** no se persisten `in_progress` ni `ready` en la rama, no se invoca ChatGPT y las 30 tendencias siguen `pending` en la cola real V2. Conectar un trabajador real y persistencia atómica será el paso 5B, no se declara completado.

## Paso 5B — prueba controlada del navegador efímero
- `browser-lifecycle.cjs` define un ciclo de trabajo único con `browserFactory`, `execute`, `persistAndVerify` y `close` en `finally`, incluso en fallo, timeout o resultado no verificado.
- `browser-lifecycle.test.cjs` prueba con navegador simulado los cierres y la barrera `ready` tras persistencia verificada. CI ejecuta `node --test v2/ttendencias/browser-lifecycle.test.cjs`.
- **Todavía NO es una prueba con ChatGPT real**: no hay navegador Windows accesible desde GitHub, ni adaptador autenticado implementado. No se abre Chrome real, no se envían mensajes, no se consumen entradas `pending`, no se toca `main`.
- Para una prueba real se necesita un ejecutor local aislado, autenticación separada y comprobación del resultado; cerrar únicamente el proceso/perfil que el trabajo haya creado, nunca Chrome 9223 compartido. Se requiere una prueba local supervisada antes de habilitar un consumidor automático.

## Paso 5D — investigación de X cuando existe incertidumbre y Listas V2 (13/11/2026)

- La instrucción editorial de `editorial_run_v2.py` exige investigar con prensa/fuentes primarias. **Si no se identifica un motivo predominante razonablemente acreditado**, debe buscar además conversaciones recientes en X y aportar URL de posts con fechas. No puede atribuir rumores ni fingir una consulta si X no es accesible. Esta es una **instrucción a ChatGPT**, no una prueba independiente de navegación X.
- Salida solicitada: `ESTADO_CAUSA: CONFIRMADA|NO_CONFIRMADA` y `ESTADO_X: CONSULTADO|INACCESIBLE|NO_NECESARIO`. Si falta el detonante, la explicación describe prudentemente el contexto y la duda, sin inventar hechos; la ausencia de certeza causal **no bloquea la ficha en Listas**.
- `listas_v2.py` proyecta las capturas completas de `captured_review` y las fichas `ready` en `v2/ttendencias/state/listas.json`, exclusivamente en la rama V2. La proyección conserva ID/revisión, texto, hash, fuente de conversación, condición de incertidumbre y referencias de X; tiene siempre `publication_allowed:false`. No hay app V2 conectada todavía, ni publicación.
- Las respuestas que dicen `CONSULTADO` se clasifican como **declaración del modelo**, nunca como prueba independiente de que X se visitó. Con `NO_CONFIRMADA` se muestra `Motivo no confirmado`. Si falta el marcador, el sistema marca `sin_clasificar`, sin inventar certeza.
- Tras capturar, verificar GitHub y cerrar Chrome, `editorial_run_v2.py` sincroniza y verifica también la proyección Listas. Si falla, se detiene el lote; no se reenvía nada. Los trabajos anteriores se pueden incorporar desde la cola con `python listas_v2.py --sync` sin abrir ChatGPT.
- Aislamiento: V1, `main`, Windows ajeno, aplicaciones, publicaciones, automatizaciones y sesiones de X existentes no se tocan. Continuar usando Chrome V2 **visible** durante desarrollo; minimización/ocultación solo en una fase posterior, tras comprobar fiabilidad.
- Tests puros: `test_listas_v2.py` comprueba que las fichas con causa incierta siguen en Listas, los borradores no se publican, las respuestas incompletas se rechazan y no se equipara la afirmación de ChatGPT con verificación.

## Top 30 cada 15 minutos y prioridad 1→30 (13/11/2026)

- **Prioridad editorial:** las tandas V2 seleccionan solo trabajos aún no enviados de la última captura aceptada del Top 30; orden por puesto **1, 2, ... 30**. `editorial_run_v2.py --next` usa el mismo criterio.
- **Una vez seleccionado, se termina:** `editorial_batch_v2.py` congela los IDs/revisiones de toda la tanda al comienzo. Si una tendencia sale del ranking antes de empezar su turno, **se elabora igualmente** según el plan congelado. Revalidar siempre la revisión, el estado y la ausencia de envío anterior, no su rango actual. Los trabajos históricos fuera del Top 30 siguen en la cola y pueden investigarse explícitamente por ID, pero no sustituyen al Top 30 en la selección automática.
- El historial y la cola deben corresponder a una misma captura y esta tener **20 minutos o menos**. Se distingue la frescura de la captura de la frescura real de la fuente X, que no está verificada independientemente.
- El workflow V2 de pasos 1–4 solo corre por `push` o manualmente desde la rama de pruebas. **GitHub no ejecuta cron de un workflow que exista solo en una rama no predeterminada.** Para no modificar `main`, se ha preparado una tarea local de Windows que solicita una actualización cada 15 minutos sin abrir Chrome. Una solicitud crea un commit idempotente del cuarto de hora en `v2/ttendencias/manual-run-trigger.txt`, rama `feature/ttactualidad-v2-clean`, y ese `push` dispara la lectura GetDayTrends y la actualización de historia/cola existentes en el workflow V2.
- Instalación, bajo el mismo usuario Windows que ya tiene `gh auth`: descargar `top30_tick_v2.py`, `Run-V2-Top30-Tick.ps1` y `Install-V2-Top30-15min.ps1` en `%LOCALAPPDATA%/TTActualidadV2`, y ejecutar este último script. Nombre de tarea: `TTActualidadV2-Top30-15m`. Dispara a los minutos 00, 15, 30 y 45, siempre **que la sesión del usuario Windows esté iniciada y la máquina esté encendida**. No se considera instalada ni verificada hasta ver `TT_V2_TOP30_TASK_REGISTERED=YES` en ese ordenador y una ejecución posterior del workflow.
- Esta programación **no activa** ni agenda la elaboración editorial, la publicación, X, imágenes ni Chrome. Los procesos ChatGPT V2 siguen visibles durante desarrollo. Registros del reloj en `%LOCALAPPDATA%/TTActualidadV2/logs-top30`. El reloj informa `SUBMITTED`, no confunde el trigger con la captura ya realizada.
- En caso de cambios de GitHub concurrentes entre el refresh de 15 minutos y el cierre editorial, se permite reintentar únicamente el **commit de la captura de la respuesta ya obtenida**, revalidando ID/revisión/token y sin reabrir ChatGPT ni reenviar el mensaje.

## Decisión arquitectónica — reutilizar V1 donde ya funciona (13/11/2026)

**Regla permanente de V2:** reconstruir limpio y mejorar solo donde haga falta; **reutilizar patrones, flujos y decisiones de V1 que ya funcionan**, sin reinventar soluciones equivalentes ni acoplar los estados, credenciales, publicaciones o sesiones de V1 a V2. Antes de diseñar una nueva pieza, inspeccionar la solución de V1 y justificar la diferencia.

**Top 30 sin ordenador:** V1 ya usa GitHub Actions `schedule`. Se adopta ese mismo patrón: workflow mínimo `.github/workflows/ttactualidad-v2-top30-scheduled.yml` en `main`, con cron `0,15,30,45 * * * *`, que llama al workflow reutilizable V2 `.github/workflows/ttactualidad-v2-step01.yml@feature/ttactualidad-v2-clean`. El llamado hace checkout explícito de la rama V2 y escribe únicamente sus archivos de estado. No toca los archivos ni los workflows de V1. GitHub Actions cron es aproximado, no garantiza ejecución exacta al segundo; monitorizar `observed_at` y salud.
El disparador Windows de 15 minutos preparado antes **queda descartado y no debe instalarse**; no es necesario mantener el ordenador encendido para actualizar el Top 30. El navegador Chrome V2 sigue siendo local para elaboración editorial hasta desarrollar una alternativa validada. El plan de tanda se congela por puestos 1→30 y no cancela una tendencia ya seleccionada aunque salga del ranking.

No confundir instalación de cron con primera ejecución verificada: confirmar en Actions el primer run `schedule` y su escritura en `v2/ttendencias/state/history.json`. Ninguna tarea de publicación V2 se activa.
