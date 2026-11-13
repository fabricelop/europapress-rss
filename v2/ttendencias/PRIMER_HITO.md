# TTActualidad V2 — Primer hito funcional (13/11/2026)

## Objetivo único de esta fase

Ver desde PC o móvil el **Top 30 de España**, actualizado automáticamente cada
15 minutos incluso si el ordenador está apagado, con un estado fiable por
tendencia y **la explicación obtenida en su conversación individual de ChatGPT**.

No incluir todavía imágenes, publicación, Instagram, X, Telegram, valoración,
botones de decisión editorial ni nuevas funcionalidades accesorias.

## Flujo exacto

1. GitHub Actions (patrón probado de V1) obtiene GetDayTrends España en los
   minutos 00/15/30/45 UTC, preserva el histórico de entradas/salidas y las
   identidades estables de V2. Fuente única aceptada provisionalmente; no afirmar
   que se observó X directamente.
2. Cada nueva tendencia no explicada entra en cola `pending`; la web muestra
   **Pendiente**. Orden de selección **puesto 1 → 30**, omitiendo las que ya
   tienen explicación vigente.
3. El consumidor V2 reclama el trabajo exclusivamente mediante GitHub CAS,
   cambia a `in_progress` y la web muestra **En elaboración**. Solo debe
   existir un Chrome/ChatGPT de V2 por tendencia, sin usar el perfil V1.
4. Abre **una conversación nueva por tendencia**, investiga, redacta una
   explicación prudente (o declara causa no confirmada), captura, cierra
   todos los procesos del navegador V2 y persiste respuesta + identificador
   + revisión + enlace al chat con verificación de lectura en GitHub.
5. La web muestra **Explicada** junto con el texto; `captured_review`
   significa explicación disponible **pendiente de validación editorial**,
   no READY ni publicada. Si falla la captura después del envío, mostrar
   **Incidencia** y recuperar el chat sin enviar otra vez.
6. Si una tendencia sale del Top 30, **no cancelar** un trabajo ya asignado:
   debe concluir y quedar en el histórico para el caso de que regrese.
   Al entrar de nuevo antes de 24 horas, conservar episodio; si han pasado
   más de 24 horas, aplicar la política de revisión vigente.
7. La web refleja ranking, posición, estado, explicación, frescura del dato y
   momento de captura. Debe funcionar en PC y móvil sin instalar software.
   El estado mostrado se deriva de GitHub V2 (autoridad única). La vista
   pública solo contiene campos necesarios; no revelar tokens/leases.
8. El refresco del Top 30 no depende del ordenador. La **elaboración con
   Chrome V2 local sí depende del PC encendido**, hasta adoptar otro ejecutor
   igual de fiable. No confundir las dos autonomías.
9. Antes de añadir piezas, revisar la solución correspondiente de V1 y
   **reutilizar el patrón probado** cuando sea adecuado. V2 mantiene
   colas, sesiones, despliegues y estado separados.

## Estados visibles

| Estado técnico | Estado web | Significado |
| --- | --- | --- |
| `pending`, `review_pending` | Pendiente | Aún no se ha iniciado |
| `in_progress` | En elaboración | Consumidor ha reservado este ID |
| `captured_review` | Explicada · por revisar | Texto capturado, no validado |
| `ready`, `published` | Explicada | Texto vigente; no significa que V2 publique |
| `capture_recovery`, `cancelled` | Incidencia | Requiere atención, sin reenvío ciego |
| `dismissed` | Desestimada | Sin nueva elaboración |

## Criterios de aceptación del primer hito

- Dos capturas programadas consecutivas con Top 30 completo y fechas distintas,
  realizadas por GitHub con el PC apagado.
- Acceso real por **HTTPS** al mismo panel desde PC y móvil y 30 puestos en
  orden, con captura reciente y aviso claro si caduca.
- Una tendencia sin explicación pasa por **Pendiente → En elaboración →
  Explicada**, reflejado en la web sin recarga manual.
- Cada trabajo usa un **chat distinto** y su Chrome desaparece por completo;
  GitHub conserva texto, ID, revisión y URL del chat.
- Una tendencia que sale mientras está seleccionada se termina sin duplicar.
- Una causa no confirmada genera ficha prudente y visible, no bloqueo.
- Ninguna acción modifica la cola de V1, publica contenidos ni toca servicios
  de producción. El primer hito no se declara terminado hasta probar su
  flujo completo, incluida la URL HTTPS.

## Estado de implementación

- Captura Top 30, historial, cola, editorial individual, captura, GitHub,
  Listas V2 y selección por posición: **implementados y parcialmente
  probados**.
- Cron remoto de 15 minutos: **configurado**, falta comprobar dos ejecuciones
  de horario consecutivas.
- Web V2: **pendiente de completar y desplegar**.
- Ejecución editorial automática que recorra el Top30: **consumidor V2 e instalador Windows implementados**; falta instalarlo y verificar el primer lote autónomo en el PC.
- Publicación V2: **desactivada expresamente**.

## Automatización editorial local (implementación inicial)

- `editorial_daemon_v2.py`: consumidor que consulta la cola y el historial GitHub V2 aproximadamente cada **90 segundos** mientras haya sesión Windows. Prioriza siempre el **Top 30 vigente (puesto 1→30)**, espera si la captura ha caducado, omite las explicadas y no procesa el backlog histórico fuera de ranking.
- Reutiliza `editorial_run_v2.run_one` (ya probado en las tandas manuales): un único navegador exclusivo y nuevo chat por tendencia, persistencia SHA, Listas y web. El siguiente trabajo empieza tras la verificación del anterior. **No hay publicación.**
- `auto_editorial_policy_v2.py` impide reenviar automáticamente un ID/revisión que ya tiene diario local. La cola GitHub verifica también `send_intent` y `lease`. Si cae la red, la sesión o la captura, el trabajo dudoso queda sin reenvío y el consumidor puede seguir con otros elegibles.
- `process_lock_v2.py`: lock de sistema operativo compartido con `editorial_batch_v2.py`; si Windows cierra el proceso bruscamente, el lock se libera, sin interpretar un archivo residual como otra instancia activa.
- `Install-V2-Editorial-Auto.ps1`: descarga todos los módulos desde **un único commit SHA V2**, ejecuta pruebas puras y comprueba Playwright y el perfil Chrome V2. Registra la tarea **`TTActualidadV2-Editorial-Auto`** al iniciar sesión Windows y la arranca en la sesión actual. NO modifica tareas de V1. Guarda logs bajo `%LOCALAPPDATA%/TTActualidadV2/editorial-auto-logs` y estado en `daemon-status.json`.
- `Disable-V2-Editorial-Auto.ps1`: impide nuevos envíos y deshabilita el próximo arranque de la tarea. El chat que esté activo puede terminar su ciclo y cerrarse con seguridad.
- **Puesta en marcha pendiente:** hasta ejecutar el instalador en Windows, el consumidor NO está activado. No confundir código listo con automatización instalada.
- La captura Top30 por cron GitHub funciona sin PC. El consumo editorial con Chrome **sí necesita Windows encendido y sesión interactiva**. Queda disponible reanudación al inicio de sesión. La captura del ranking, la web y las explicaciones comparten siempre el estado de la rama V2.
- El consumidor no renueva ni vuelve a enviar automáticamente una sesión dudosa, aunque su lease haya vencido; la web la identifica como incidencia. La recuperación del chat existente se tratará después de validar el primer lote automático.

### Validación de seguridad
`python -m unittest test_auto_editorial_v2.py` desde el directorio V2 comprueba la selección por ranking, parada por captura caducada, bloqueo de reenvío, exclusión entre procesos y continuidad del plan seleccionado si el término sale del Top30. GitHub CI ejecuta estas pruebas sin navegador ni cambios de producción.

## Reparación del primer consumidor autónomo — 13/11/2026

- Primera elaboración autónoma real: **Jordi Wild**, ID exacto
  `trv2-e94b2984c087ac403753b8c1`, revisión 1. Se guardó la intención de
  envío y se encontró el chat, pero Windows terminó el proceso antes de capturar
  la respuesta. Chrome V2 quedó abierto. **No se permite reenviar la orden**.
- Se reutiliza el ciclo editorial V2 ya probado y se mejora la recuperación:
  `chatgpt_transcript.py` reconoce la interfaz en español e inglés y extrae
  una respuesta de un único par de turnos DOM verificado; el ciclo normal puede
  observar hasta 15 min una investigación, con reserva de 40 min.
- `recover_existing_chat_v2.py --auto` se conecta por CDP SOLO al Chrome del
  perfil V2 existente, exige **un único** journal local que coincida con la
  cola en GitHub en ID/revisión/token, lee la respuesta sin enviar, verifica
  identidad, cierra solo Chrome V2, persiste en la cola y sincroniza Listas/web.
  Si no identifica la conversación o no puede verificarla, **no cierra el
  navegador ni arranca nuevas elaboraciones**.
- `Run-V2-Editorial-Auto.ps1` recupera un chat previo ANTES de iniciar nuevos
  trabajos. Reemplaza el pipe PowerShell largo `Tee-Object` por redirecciones
  de salida a archivos separados, para que el cierre del pipeline no afecte
  a la supervisión del navegador.
- El instalador `Install-V2-Editorial-Auto.ps1` detiene temporalmente el
  programador, mantiene el diario y perfil Chrome, descarga un commit coherente,
  ejecuta pruebas, recupera el chat previo sin reenvío, y **solo después**
  reactiva la tarea `TTActualidadV2-Editorial-Auto`, con dos disparadores:
  al iniciar sesión y cada **3 minutos** para rearmar el consumidor si Windows
  lo termina (sin lanzar duplicados por `IgnoreNew` y bloqueo SO).
- Estado **implementado y probado estáticamente en CI**; **la recuperación y
  reinicio reales en Windows están pendientes** de ejecutar el instalador
  corregido. Nunca declarar el chat recuperado ni siguiente tendencia lanzada
  antes de ver prueba en logs/GitHub.

## Incidencias recuperables y ejecución oculta (13/11/2026)

**Política solicitada:** una tendencia en `capture_recovery` o una `in_progress` con lease vencido NO queda permanentemente bloqueada. El único consumidor V2 selecciona las incidencias del Top30 **por ranking 1→30** y aplica este orden antes de abrir nuevas conversaciones:

1. Asegurar que no hay ningún proceso Chrome del perfil V2 abierto y que el consumidor mantiene su lock local.
2. Si el diario conserva una respuesta completa, intentar persistir esa MISMA respuesta primero.
3. Si conserva URL de conversación previa y evidencia del envío, abrirla **solo para lectura** en Chrome V2 oculto y recuperar el texto original, sin otro Enter.
4. Si no se puede recuperar, y han pasado **8 minutos** desde el estado de recuperación o desde el vencimiento del lease, crear una **nueva revisión** del mismo ID con estado `pending`; archivar el ID/revisión/URL/fecha/causa del intento anterior. Nunca reusar el token de envío, lease ni diario de la revisión antigua. Continuar el ranking; la tendencia nueva pasará a `in_progress` en su siguiente selección.
5. Hasta **dos reintentos automáticos por incidencia** (máximo tres revisiones de este ciclo). Al agotar el límite, mantener «Incidencia» para diagnóstico, nunca un bucle de chats. Un trabajo vigente no se cancela al salir del Top30, y uno histórico con incidencia espera a entrar de nuevo.

Implementación: `incident_retry_v2.py` (transición pura), `incident_worker_v2.py` (rescate y CAS GitHub), `recover_existing_chat_v2.py` (lectura del chat previo por URL). Unit tests: `test_incident_retry_v2.py`.

**Ejecución oculta:** siguiendo el patrón probado del watchdog de V1, el runner usa `Start-Process -WindowStyle Hidden` y redirige logs; la tarea Windows añade `-WindowStyle Hidden`. Chrome V2 utiliza `--headless=new` con el MISMO perfil aislado y puerto CDP localhost. `headless_preflight_v2.py` comprueba que el ChatGPT autenticado carga y su editor está operativo **sin enviar mensajes**; si falla, el instalador deja la tarea inactiva, sin reenviar ni publicar. Solo V2 cambia de modo, nunca V1. `Upgrade-V2-Hidden.ps1` desactiva nuevos trabajos, deja concluir el actual, actualiza los módulos y rearma la tarea. No mata Chrome ni borra capturas.

**Lanzamiento:** cambios de GitHub implementados; la activación local de este modo permanece pendiente hasta ejecutar el upgrade en Windows. La salida de CI (93 tests en la última comprobación) valida lógica estática, no sustituye la prueba real del perfil autenticado en headless.

## Reparación de preflight headless residual (13/11/2026)

La primera actualización a modo oculto pasó pruebas de Python/Playwright y
`RECOVERY_ORPHAN=NONE`, pero no reactivó V2: el preflight terminó con
`TT_V2_HEADLESS_PREFLIGHT_ERROR=Quedan procesos Chrome V2 tras prueba headless`.
No se envió ningún mensaje; el instalador dejó correctamente tarea y bandera
V2 deshabilitadas. La causa técnica probable es que el cierre verificaba solo
los PIDs de una primera instantánea; Chrome puede crear hijos después. El
primer error de CDP/login podía quedar ocultado por la excepción de limpieza.

Reparado en `chrome_cleanup_v2.py`: solo enumera procesos del
`TTActualidadV2/ChromeProfile` mediante `core.profile_pids()`, intenta
cerrar sus árboles y vuelve a comprobar hasta dos rondas sin procesos. El
preflight mantiene lock exclusivo V2, conserva cualquier error original y
registra `HEADLESS_CDP`, `HEADLESS_COMPOSER_READY`,
`HEADLESS_CLEANUP_REMAINING` y `HEADLESS_PROCESSES_CLOSED` sin enviar nada.
El mismo cierre reforzado se comparte con las elaboraciones y con los
rescatadores de chats, para evitar posteriores bloqueos al cambiar de tema.

`Repair-V2-Headless-After-Preflight.ps1` es la única entrada de reparación
para este caso concreto: exige tarea V2 **Disabled**, bandera exacta
`AUTO_EDITORIAL_ENABLED=NO`, ningún consumidor V2 activo y dos registros
locales que demuestren prueba fallida **sin envíos**. Solo puede terminar
`chrome.exe` con el argumento `--user-data-dir` correspondiente al
perfil V2 exacto y creado en la ventana de esa prueba. No toca V1, ni
resetea/reenvía ningún trabajo. Si alguna comprobación falla, aborta sin
reactivar la tarea. Tras limpiar, descarga e instala la última revisión
consistente de V2, valida el editor oculto y solicita arranque automático.

Pruebas puras Linux/CI validan hijos tardíos, dos lecturas vacías, ausencia
de terminación fuera del conjunto de PIDs V2, y errores de cierre no ocultos.
La ejecución **real en Windows** continúa pendiente de verificar; no dar
por activado el modo oculto antes de ver `TT_V2_HIDDEN_REPAIR_INSTALLED=YES`.
