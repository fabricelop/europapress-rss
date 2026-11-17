## Piloto editorial: corrección validada e integrada (17/11/2026)

CI aislado44034435792 SUCCESS en Linux y Windows:
224 Python,108 Node, compilación/parseo PowerShell, TaskScheduler/WSH oculto
y nueva prueba REAL PowerShell de las guardias del piloto extraídas por AST.
PASS: TTN2_PILOT_VERIFIED_QUARANTINE_GUARDS=PASS.
Se integra el parche e7842df0808db067b64a0a7a2f8e0b4df00a9d9c.

El nuevo run-one devuelve quarantined/exit0 solo ante ContractError con envío
confirmado, captura completa y persistida, incidencia persistida y cierre verificado.
El instalador verifica todas esas condiciones y permite activar la automatización.
No produce READY de una noticia rechazada. Sin esos recibos mantiene incident/exit1.
Esto evita que otro ESSENTIAL_FACT_NOT_VERIFIED del piloto vuelva a bloquear
toda la cola, sin rebajar investigación ni verificación.

Estado último:81 pendientes/0 activos/3 READY/2 incidencias. Las dos rechazadas
permanecen intactas; no se reenvían. WScript/Hidden y proceso de imagen independiente
conservados. Falta CI de integración y ejecución del instalador corregido en el PC.
No repetir el actualizador con drenaje25min; usar Install-News-Editorial-V2.ps1
-EnableImages cuando se entregue el commit de integración validado.

## Noticias: rechazo del NUEVO piloto — corrección en validación (17/11/2026)

El usuario instaló efd5f6538c9e0243c38d0a0ac912960fc08fa6a8 y confirmó
blocking_recovery_incident_count=0/quarantined_incident_count=1.
El guardado previo dejó de bloquear correctamente; sin embargo el nuevo piloto
ttn2-1319f0613d6020652dd0dfa4-r1-editorial también devolvió ESSENTIAL_FACT_NOT_VERIFIED.
Arranque Chrome: ready=true, hijos propios detectados, launcher_code0.
cleanup_verified=true. GitHub confirma envío confirmado y captura completa,
SHA45cb60325d234df96a8f47ce2607db8037db91e9b043e3da922043ad73927f23.
El instalador antiguo sigue abortando ante CUALQUIER exit1 del nuevo piloto,
de modo que una segunda validación de contenido vuelve a impedir la activación.
No es el mismo fallo del contador previo y no debe pedirse otro reintento aún.

Corrección aislada en fix/news-v2-pilot-quarantine-20261117,
commit e7842df0808db067b64a0a7a2f8e0b4df00a9d9c:
- Resultado quarantined solo para ContractError tras envío/captura/guardado
  de incidencia/cierre realmente verificados; no produce READY ni publicación.
- El CLI e instalador admiten ese ciclo de transporte completo, dejando el caso
  aislado y permitiendo continuar las demás noticias e imágenes.
- Fallos de auth/envío/captura/persistencia/cierre o excepciones no previstas
  conservan incident/exit1. No se elimina ninguna barrera de seguridad.
- Seis regresiones Python y evaluación real en PowerShell de las guardias AST
  del instalador, sin ejecutar instalación, tareas ni Chrome.
- CI44034435792 EN CURSO. No integrada ni entregada como validada aún.

Estado real leído:81 pendientes,0 activos,3 READY,2 problematic.
Conservar ambas noticias rechazadas sin reenviar. Windows sigue sin activación
confirmada de esta corrección. WScript oculto se mantiene.

## Reanudación 17/11/2026 — estilo editorial y estado de imágenes

- Petición editorial explícita del usuario: reducir la repetición de 'no hay acontecimiento concreto', 'no se confirma que sea la tendencia', 'no está confirmada' y cierres equivalentes. Preferir arranques breves 'Podría ser tendencia por...' o 'Apunta a...' cuando existan indicios, sin inventar causalidad ni ocultar incertidumbres importantes.
- Commit `c8d829e6d4e59e30fe6e5ff307ddfdcc99b28db5`: modificado `editorial_run_v2.py` en `prompt_for` para empezar por hecho/hipótesis concreta, expresar duda una sola vez en condicional, dejar detalle de fuentes fuera del texto principal para X (máximo 155 caracteres), y no cerrar con muletillas repetitivas. Sigue exigiendo investigación y etiquetas técnicas de confirmación. Solo afecta a nuevos prompts después del despliegue local; no reescribe fichas existentes.
- Commit `410a91953147b3e03d48308135a30647695a92a0`: clasificador `image_retry_status_v2.py` no trunca los intentos históricos al mostrar el contador. IMPORTANTE: clasificador aún no conectado al Site ni alimentado por diarios locales; no presentar el contador como operativo.
- Pendiente imprescindible: pruebas del clasificador y del prompt, sincronización de estado de reintentos al backend seguro y visualización al abrir tendencia; despliegue controlado en Windows. No se ha desplegado ni publicado ni relanzado una tendencia.

## Noticias: corrección integrada y CI completo — 17/11/2026

Commit de código validado: 1af7ad669e022a3638e175477994753f12d1982a.
Run44032975102 SUCCESS:218 Python +108 Node en Windows/Linux, parser PowerShell,
XML Task Scheduler y ejecución WSH real para lanzadores sin consola.
Run44032975167 SUCCESS: regresiones editoriales en ambos SO y preview real
del commit21a5291f4ccff3c1dcaf82d4125cc13b08b0c27e:82 pendientes,0 activos,max3.
No se realizaron claims/envíos/READY durante estas comprobaciones.

Siguiente acción de PC: descargar Install-News-Editorial-V2.ps1 del commit
1af7ad669e022a3638e175477994753f12d1982a y ejecutarlo con -EnableImages
en la consola existente. No hace falta repetir Upgrade/drenaje25min para
el bloqueo ya terminado. El instalador abortará si detecta un consumidor vivo.
Debe informar TTN2_EDITORIAL_INCIDENTS_QUARANTINED=1 (Lindsay Clancy se conserva
sin reenviar), verificar el nuevo piloto y solicitar los tres puestos editoriales
y los dos de imagen con WScript oculto. Falta comprobar su salida local real.

Mantener la distinción: código/CI completados; instalación y tareas locales de
esta corrección aún no confirmadas. Registro actualizado sin sustituir los
cambios nocturnos de Tendencias ni el requisito separado de presupuestos de imágenes.

## Noticias: desbloqueo de validación capturada — 17/11/2026

Retomado ESTE chat tras leer memoria maestra v315 y el registro de la noche.
La corrección validada d72784e9a58a4822e0a624187dda1b6e792cd36a estaba solo en
fix/news-v2-quarantined-validation-20261116, aún sin integrar. Se integra ahora
únicamente en cuatro archivos de Noticias, conservando los cambios recientes
de reintentos de imágenes de Tendencias y su planificación independiente.

Evidencia local aportada por el usuario:
Upgrade terminó el drenaje8→0, instaló dfaf4fd0f2e726395aef2196bfb825242817a578
y abortó antes de activar tareas con CODIGO_SALIDA=1, recovery_incident_count=1.
No fue un fallo de dependencias ni de Chrome en esa ejecución.
La noticia ttn2-2618ba0b211ec516822f0794 (Lindsay Clancy) tiene envío CONFIRMADO,
captura completa SHA68cb2d3851e3ea2b7f289a6d1d7d20bb8b87edcb600665531eb2c44804e8e7b0,
pero falló con ESSENTIAL_FACT_NOT_VERIFIED. El mensaje anterior del instalador
que hablaba de envío sin confirmar era incorrecto para este caso.
No crear READY ni reenviar esa noticia: conservarla en incidencia para revisión.

Cambio:
- preview distingue blocking_recovery_incident_count (envío incierto/captura
  incompleta) y quarantined_incident_count (envío confirmado y captura completa).
- El instalador solo bloquea ante la primera categoría; registra la segunda
  sin reenviar ni impedir que se elaboren otras noticias o sus imágenes.
- Conserva WScript/Hidden y el proceso independiente de imágenes existente.
- CI aislado43971508835 SUCCESS:218 Python/108 Node en Linux y Windows, parseo,
  XML TaskScheduler/WSH reales. CI43971508712 SUCCESS con preview real:
  blocking=0, quarantined=1, sin escrituras ni navegador.
- La prueba garantiza que la noticia fallida queda idéntica al reservar otra.

Estado real al retomar: 82 pendientes/0 activas/3 listas/1 incidencia;
radar actualizado 2026-11-17T02:31:36Z (supera la observación antigua19:11:32Z).
Instalación de esta corrección y activación local de3+2 puestos AÚN PENDIENTES.
Siguiente: CI de integración y entregar Install-News-Editorial-V2.ps1 -EnableImages
desde commit validado. No repetir el drenaje completo si no hay procesos activos.
El propio instalador comprobará esto y abortará ante un consumidor vivo.
No iniciar recuperaciones manuales de imágenes por tendencia: el requisito nuevo
de presupuestos/reintentos de Tendencias de la memoria v315 sigue independiente.

## Reanudación 17/11/2026 — límite preenvío y clasificador de estados

- `9501e93ff7ed636b650bfc9bdbd3834fa358389d`: `image_worker_v2.py` limita a 3 los fallos `pre_send_failed` por revisión, con cooldown 900 s; siguen separados de los tres intentos de envío. Evita ciclos infinitos del navegador ante un compositor roto.
- `80c4b910355f525929c2543550c5903dfa391056`: nuevo módulo puro `image_retry_status_v2.py` para clasificar, conservadoramente, `pending`, `retry_pending`, `exhausted`, `unverified`, `saved` a partir de diarios de una revisión; devuelve presupuestos de envío y preenvío. Los casos ambiguos no se consideran reenviables.
- `c4695d003adaba80c265fd1228737700bb135788`: pruebas unitarias de estos estados añadidas; todavía NO ejecutadas/validadas en CI.
- MUY IMPORTANTE: el clasificador aún no está conectado al snapshot público ni al Site V2. Los diarios son locales y no deben exponerse íntegros. La interfaz aún NO muestra intentos restantes/agotados; no dar por terminada esta petición. No se ha desplegado nada en Windows ni se han reenviado imágenes.
- Objetivo vigente del usuario: al abrir cada tendencia ver si aún habrá generación automática o si agotó intentos; sin recuperación manual backend por tendencia, con opción manual existente. Se debe alinear clasificador y planificador, proyectar solo estado seguro y validarlo en web.

## Decisión funcional usuario: visibilidad del presupuesto de imágenes — 17/11/2026

El usuario RECHAZA recuperar casos individualmente de forma manual desde el backend: ya dispone de botones de generación/pegado manual en la ficha. Acepta un mecanismo automático general, pero su requisito principal es que AL ABRIR CADA TENDENCIA se vea de forma inequívoca si la imagen todavía puede generarse automáticamente o si ya no quedan intentos y debe decidir usar el procedimiento manual.

Contrato de interfaz pendiente: estados diferenciados `generando`, `reintento automático pendiente` con intentos restantes, `agotada` sin más intentos, `envío incierto/bloqueado por seguridad`, `imagen guardada`; mostrar `n/3` solo para intentos de envío realmente contabilizados, y limitar separadamente los preenvíos fallidos para no generar bucles ilimitados. No confundir `image_incident.code` con presupuesto de reintentos. El snapshot público `web_top30_v2.py` hoy solo expone bandera de incidencia/progreso; el estado real deberá derivarse del planificador/journals y proyectarse de forma segura sin exponer comandos, chats ni datos privados. No está implementado ni probado. No lanzar recuperación manual por tendencia.

## Observación usuario web V2 e imágenes históricas — 17/11/2026

- Captura de la web V2 aportada por el usuario: hay numerosas imágenes nuevas y tarjetas con incidencia visible. Ejemplo `#SánchezEnT5` presenta `V2_IMAGE_PROMPT_NOT_SUBMITTED` (registrada 16/11/26 23:37) junto a su texto editorial y controles RE/RE-X/P-X. Esto verifica presentación de la incidencia, NO que el parche más reciente esté instalado localmente.
- Política de `next_attempt` verificada: máximo tres diarios con `send_protocol=2`; los fallos pre-envío de nuevo tipo `pre_send_failed` permiten otro intento tras 900 segundos, sin consumir el cupo de envíos; los fallos antiguos agotados no se reactivan solos. Los envíos ambiguos no deben repetirse sin comprobación.
- Necesidad funcional: recuperación automática controlada de fallos históricos confirmados sin envío, sin obligar al usuario a RE/RE-X ni alterar el texto editorial; preservar anti-duplicados y permitir que el worker continúe con otros candidatos. Aún NO implementada ni probada. Distinguir el éxito parcial visible (otras imágenes) de recuperación de imágenes fallidas.

## Corrección de contabilización preenvío y memoria maestra — 17/11/2026

- La memoria maestra es el documento de Biblioteca `libfile_c244fcbdb29c8191a1d37f82a7ba3aa5` (`TTActualidad-Memoria-Completa-2026-10-29.md`); se localizó en Biblioteca, 405188 bytes, versión de archivo 1, revisión documental 16/11/2026. NO es lo mismo que este registro de continuación de GitHub. No se ha sobrescrito todavía la memoria maestra.
- Commit `09439c54374a6e8e00e09ffe4c5ac230de96731d`: `submit_image_prompt` acepta callback `before_click`, que persiste `send_intent_recorded` únicamente cuando existe botón visible/habilitado y justo antes de pulsarlo. Ausencia/deshabilitación del botón o prompt ausente antes del clic se registra como `pre_send_failed`; `next_attempt` permite un número nuevo tras cooldown de 900 segundos, sin consumir cupo de intentos de envío confirmado. Persisten las restricciones anti-duplicado de intentos inciertos.
- LÍMITES: el código no ha sido desplegado en Windows, no hay prueba de interfaz real ni suite ejecutada todavía. No afirmar que las imágenes pendientes se hayan recuperado. El registro de fallos preenvío puede seguir creciendo si persiste un fallo estructural: revisar política de alertas/bloqueo. No cambiar V1, SeLoRecordamos ni publicación automática.

## Ajuste de envío de imágenes — 17/11/2026

- Commit `ecd10f6c1c7025ee9c7300af03e664914c68efa7` en `feature/ttactualidad-v2-clean`: ampliados los selectores de botón de envío (`send-message-button`, etiquetas accesibles Send/Enviar/Enviar prompt); `submit_image_prompt` ya no abandona el sondeo en la primera ausencia, sino que espera hasta 15 s; comprueba `aria-disabled`. Continúa prohibido el fallback Enter.
- Motivación: diarios mostraron intentos con `send_trigger=enter`, prompt retenido en compositor y ningún turno verificado. La conexión Playwright al puerto CDP temporal 61072 falló después con `ECONNREFUSED`; no demuestra un problema de instalación.
- Estado honesto: cambio de GitHub SIN despliegue local, SIN validación funcional contra la interfaz real, SIN reenvíos. Pendiente prueba automatizada de selectores, diseño del estado pre-envío para no consumir intentos y despliegue controlado en Windows. Mantener publicación automática desactivada.

## Corrección preventiva del envío de imágenes — 16/11/2026

- Diagnóstico real del usuario: Python 3.14.6 y `PLAYWRIGHT_IMPORT=OK`; `connect_over_cdp` a 127.0.0.1:61072 devolvió `ECONNREFUSED` porque el puerto temporal ya no escuchaba. El CDP sí había respondido en la prueba previa. No confundir esta conexión caducada con fallo de instalación Playwright.
- Inspección del código de `image_worker_v2.py`: `submit_image_prompt` intentaba botones conocidos y, si no aparecían, ejecutaba `composer.press("Enter")`. En los diarios fallidos Enter dejaba el command_id en compositor sin turno de usuario.
- Commit `2a27c6db565ccc7124e72c73f9b0022cdc9eb83f` en `feature/ttactualidad-v2-clean`: eliminado el fallback Enter; ahora lanza `V2_IMAGE_SEND_BUTTON_UNAVAILABLE` con descripción pública segura si no encuentra botón verificable. No se añadió selector especulativo, no se envió ningún prompt y no se modificó la publicación.
- LIMITACIÓN IMPORTANTE: el trabajador todavía registra `send_intent_recorded` antes de llamar a `submit_image_prompt`; por tanto este cambio previene envíos Enter fallidos, pero aún NO corrige por completo el consumo de intentos en casos de botón ausente. Pendiente diseñar preflight/estado retry sin duplicados, pruebas y despliegue local. El código GitHub no implica que el proceso Windows activo haya sido actualizado.

## Incidencia inspección Playwright — 16/11/2026

El usuario intentó ejecutar la inspección de botones del compositor en Chrome de imágenes. PowerShell devolvió únicamente el inicio de `py : Traceback (most recent call last):` y un `NativeCommandError`, sin excepción Python final. La causa es DESCONOCIDA; no atribuirla aún a Playwright, CDP o al script. Se facilitó diagnóstico mínimo con traceback completo capturado por stdout para verificar importación de Playwright, conexión CDP al puerto previamente observado 61072 y número de páginas, sin enviar prompts ni tocar trabajos. Pendiente resultado. No hay parche de producción aplicado.

## Seguimiento diagnóstico CDP imágenes — 16/11/2026

El usuario ejecutó el diagnóstico PowerShell sin psutil: `CDP_PORT=61072`, dos páginas ChatGPT (`conversation` y `home_or_other`), ambas con depuración disponible, `CDP_ACCESS=OK`. Queda descartada una indisponibilidad general del CDP en ese instante; NO prueba que el envío del prompt funcione. Siguiente prueba entregada: inspección de solo lectura mediante Playwright existente, conectando al puerto 61072, que devuelve únicamente atributos de botones y compositor (sin texto de mensajes ni clicks). Pendiente respuesta del usuario antes de parchear. No se ha modificado código de producción ni se han reenviado imágenes. Mantener publicación desactivada.

## Diagnóstico operativo Tendencias V2 — 16/11/2026, imágenes (continuación)

- Editorial: 11 identificadores distintos en diarios locales con `editorial_persisted` (Austria `editorial_persisted_recovered`); envío, captura y persistencia True. El contador `completed=0` del daemon no equivale a ausencia de persistencias.
- Imágenes: 14 registros de imagen guardada entre los 30 logs examinados; 15 logs con errores. Casino Royale (`trv2-9d0cf136b041584656835139`) intentos 1 y 2: `V2_IMAGE_PROMPT_NOT_SUBMITTED`. `#SánchezEnT5` (`trv2-f9f44f661d62b80aef779f1f`) intentos 1 y 2 iguales; intento 3 observado `sent_waiting_for_image`, sin desenlace confirmado.
- Observaciones de los fallos: `send_trigger=enter`, URL inicial `https://chatgpt.com/`, `user_turn_contains_command=False`, `composer_contains_command=True`, `composer_inspected=True`, sin chat identificado. Sospecha fundada: Enter no está enviando el prompt; no afirmar causa UI definitiva sin inspección.
- Código inspeccionado: `v2/ttendencias/image_worker_v2.py` usa Enter como fallback si no reconoce botón de envío; `image_target_tracker_v2.py` espera conversación verificada hasta 150 s. No cambiar reintentos ni reenviar trabajos ambiguos sin verificar.
- El primer diagnóstico de botones no se ejecutó: `FALTA_PSUTIL`. Se entregó diagnóstico alternativo solo PowerShell/CDP sin dependencia psutil; pendiente salida del usuario. No se ha aplicado parche de envío ni reiniciado procesos.
- Seguridad: `publication_allowed=false`; conservar 14 imágenes ya guardadas, historial, chats y trabajo editorial. No alterar V1 ni los procesos compartidos.
- Próximo paso: comprobar Chrome de imágenes con CDP y después inspeccionar controles del compositor con Playwright existente, sin enviar; corregir fallback y añadir regresiones antes de desplegar.

## Consolas ocultas — corrección validada e integrada

16/11/2026. Prueba en rama aislada d5404de3fe3cef9c90e7ac007cc086bfe68e81d3,
run43969877237 SUCCESS en Linux y Windows:213 Python/108 Node, parseo PowerShell,
XML real Task Scheduler y WScript real con ruta que contiene espacios.
PASS: conservación de triggers/principal/Enabled/IgnoreNew, rechazo de acciones
ajenas, idempotencia, proceso hijo terminado y exit code17 propagado.
Se incorpora Launch-News-Hidden.vbs al instalador; ambas tareas usan wscript.exe,
Settings.Hidden=true y sus launchers existentes conservan redirecciones a logs.
No se modifican trabajadores, Chrome, banderas ni tareas de Tendencias/SeLo.

Para instalaciones que hayan terminado antes de recibir este cambio:
Repair-News-Hidden-Launchers-V2.ps1 actualiza SOLO las acciones futuras de las dos
tareas Noticias conocidas. Respalda XML y wrapper, conserva programación/principal/
estado habilitado. No detiene/reinicia procesos ni tareas en ejecución.
Ejecutar una sola vez DESPUÉS de que termine la actualización ya en curso.
Si el instalador nuevo ya usó WScript, el reparador es idempotente.

La salida TTN2_WAIT_OWN_WORKERS=8 del usuario sigue siendo evidencia de drenaje,
no de ocho chats ni de instalación terminada. Falta su resultado final.
No ocultar/cerrar remotamente la consola personal donde lanzó manualmente
el comando; esa ventana permanece hasta que termine o el usuario la minimice.

## Corrección de consolas — en validación

El usuario está ejecutando Upgrade-News-Workflow-V2.ps1; ha mostrado repetidamente
TTN2_WAIT_OWN_WORKERS=8. Esto cuenta procesos coincidentes, no ocho chats probados.
No interrumpir el drenaje ni iniciar una segunda instalación mientras siga activo.
Causa del destello de consola: tareas Noticias lanzan powershell.exe directamente;
-WindowStyle Hidden no evita siempre la creación inicial de consola.
Corrección aislada en fix/news-v2-hidden-launchers-20261116,
commit d5404de3fe3cef9c90e7ac007cc086bfe68e81d3: WScript (modelo ya probado en
Tendencias), tarea Hidden y reparador selectivo de acciones futuras.
El reparador conserva triggers, principal, banderas Enabled y MultipleInstances;
no reinicia/termina trabajos, Chrome ni otros servicios. Con respaldo XML.
Se está comprobando en Windows con XML real y ejecución WSH de prueba que
espera al hijo y devuelve su exit code. Aún no integrada ni aplicada localmente.

# Noticias V2 — entrega y continuación

**Código validado:** 62729b18586c155bb2dde071c4c97a519485d262.
**CI:** run43967677128 SUCCESS,213 Python +108 Node en Linux y Windows;
compilación y todos los instaladores PowerShell verificados.
**CI editorial adicional:** run43967676922 SUCCESS (Linux/Windows y preview FIFO real, sin escrituras).
**Web desplegada:** run43967159798 SUCCESS,
Worker1d6dfe24-1688-4d84-b1fb-9371766571a7.108 Node +63 Python y navegador PASS.
PUB→Archivo y todos los botones comprobados en fixtures efímeras; ningún dato
editorial real fue alterado por QA. Feed público real verificado con1 noticia.
D1, secretos, bindings y cron de Tendencias conservados.

## Resultado del encargo

1. Editorial automático preparado:3 puestos CAS/FIFO, chat nuevo por noticia,
   paso a Elaboradas después de registro verificado y cierre propio.
2. Imágenes independientes preparadas:2 puestos, chat nuevo por imagen, original
   raster/hash/ID/revisión. En reposo no se lanzan hijos; no se reenvían envíos inciertos.
3. Botones de Noticias desplegados con acciones persistentes. RE/RE-X conservan
   historial; pistas privadas; P-X/P-IA preparan compartir, PU solo registra.
4. PUB→Archivo desplegado y persistente; no envía a X. Reflejo posterior en
   GitHub al ejecutar el consumidor, además del estado inmediato en D1.
5. Feed/adapter V2→V1 preparado y probado; **Site V1 aún sin conectar**.
   Identidad exacta appgprj_6ae4dcf7d7488191a574e5b649e67370, v97, público.
   Fuente independiente en git.chatgpt-team.site, inaccesible para edición sin
   ejecutor/Git local. No confundir un commit de europapress-rss con ese despliegue.

## Siguiente acción local

Ejecutar v2/ttittulares/Upgrade-News-Workflow-V2.ps1 del commit validado62729b...
Drena SOLO Noticias, conserva Tendencias/SeLo/V1/Chrome personal, ejecuta piloto
editorial y piloto de imagen y después solicita tareas independientes3+2.
Si falla imagen, la tarea editorial ya verificada continúa; incidencia disponible.
Solicitar/leer salida final y registros: no afirmar que Windows está activo aún.

Tras ello verificar noticia nueva READY, imagen original asociada en V2 y cierre
de Chrome por trabajo. Cola observada anteriormente61 pendientes/0 activos/1 lista.
Radar todavía19:11:32Z: investigar su reloj como tarea separada.

## Siguiente acción sobre Site V1

Abrir su fuente conservando identidad/audiencia y aplicar
site-patches/news-v2/news-v2-adapter.mjs según README.md.
Sustituir solo Noticias activas; preservar Inicio, Hemeroteca, relaciones, URLs
históricas, imágenes y Tendencias. Probar y publicar en SU proyecto; anotar
versión real nueva. Este chat no modificó ese Site por la limitación del ejecutor.

La memoria maestra conocida es v313 (libfile_c244fcbdb29c8191a1d37f82a7ba3aa5).
Conciliar este registro en el mismo documento con control de versión cuando
haya acceso de escritura de archivos; no crear otra memoria maestra.

## Evidencia detallada anterior

# Noticias V2 — registro de continuación

## Estado vigente — 16/11/2026 (última comprobación)

Memoria maestra leída: v313, libfile_c244fcbdb29c8191a1d37f82a7ba3aa5.
Encargo: automatizar redacción3 + imágenes2, paridad de botones, PUB→Archivo,
y Noticias V2 como fuente del Site público V1. Mantener V1 ChatGPT retirada,
Tendencias/SeLoRecordamos/Chrome compartido intactos.

### Construido y probado
- Consumidor editorial: tres puestos globales CAS/FIFO, chat nuevo por noticia.
  Integra decisiones RE/RE-X y conserva registros anteriores por revisión.
- Consumidor independiente de imágenes: dos puestos globales, chat nuevo por imagen,
  original raster verificado, SHA/ID/revisión, cierre propio antes de asociación.
  Envío ambiguo queda en incidencia y nunca se reenvía automáticamente.
- UI/API: R, RE, RE-X, P-X, PU, PUB, copiar prompt, GPT IMA, Pegar IA (PNG original),
  Quitar/Restaurar IA, visibilidad en V1 y P-IA cuando hay imagen. I muestra causa real.
- PUB mueve inmediatamente Elaboradas→Archivo en D1 sin enviar a X. El consumidor
  refleja después la decisión en GitHub; el original/historial no se borran.
- RE-X/pistas privadas: /api/news-worker-controls exige credencial GitHub del
  propietario, validada contra su identidad en api.github.com. No guardar token.
- Feed público: /api/public-news (hasta30 fichas) y /api/public-news-image con
  revisión, hash y visibilidad. No incluye pistas del editor.
- Instalación conjunta: Upgrade-News-Workflow-V2.ps1 drena SOLO Noticias sin matar
  Chrome. Instala/pilota editorial y luego imágenes de forma independiente.
  Tareas al inicio de sesión y cada3min, IgnoreNew y locks. Banderas separadas.
- CI del código c32f538edb545d8f2b65e11cf418c1ffb2491769:
  run43967030968, Linux/Windows:212 pruebas Python +108 Node PASS,
  compilación y parseo PowerShell PASS. CI editorial anterior fue corregido para
  incluir las nuevas dependencias del paquete: run43966205102 SUCCESS.

### Despliegue comprobado
- run43966604710 SUCCESS, Worker252c5014-4516-4077-af32-455a53a1cc84.
-108 Node +62 regresiones Python (incluidas Tendencias) +navegador PASS.
  QA comprueba botones, PUB→Archivo, filtros, búsqueda, errores, móvil y botón I.
  Fixtures solo efímeras: no se archivó ni fabricó ninguna noticia real.
- Credenciales, bindings, D1 y cron conservados. Feed real verificado con1 noticia.
- Última mejora de cabecera para incrustar imágenes autorizadas desde V1:
  commit68dc439800a53437055d40f3ea0697e8eb62e79e, despliegue43967159798 EN CURSO.
  Esperar el resultado final antes de declararlo desplegado.

### Operación real todavía por comprobar
- Windows: no hay evidencia de ejecución del nuevo instalador ni arranque de
  estos tres editores/dos generadores. NO describirlos como procesos activos.
- Cola observada:61 pendientes/0 activos/1 lista (Alcaraz recuperada sin reenviar).
- Radar observado sigue19:11:32Z; cron declarado no demuestra captura nueva.
- Ninguna imagen real de Noticias ha sido generada por este consumidor todavía.
- PUB/acciones web sí están desplegados; reconciliación GitHub requiere consumidor.

### Site V1: pendiente por acceso a su fuente independiente
- Site appgprj_6ae4dcf7d7488191a574e5b649e67370, v97, público,
  https://ttactualidad.rainyraven22.chatgpt.site
- NO modificado. Su Git está en git.chatgpt-team.site y no en europapress-rss.
  Este chat carece de ejecutor/transporte Git; no se puede editar ese origen aquí.
- Preparados site-patches/news-v2/news-v2-adapter.mjs y README.md: sustituir SOLO
  el loader de Noticias activas; conservar Hemeroteca, relaciones, URLs antiguas,
  datos históricos y Tendencias. No confundir este adaptador/feed con despliegue V1.

## Plan inmediato para continuar

1. Consultar run43967159798 y CI editorial43967031078; corregir fallos reales si
   los hubiera. Guardar versión final del Worker y resultados en ESTE registro.
2. Entregar Upgrade-News-Workflow-V2.ps1 desde el commit validado al propietario.
   Esperar salida de los dos pilotos, cierre verificado y arranque de tareas.
   No reenviar Alcaraz ni reabrir trabajos con envío incierto.
3. Tras instalación: comprobar noticia real nueva READY, imagen original con
   ID/revisión/SHA y visible en V2, independencia de los procesos y cierre Chrome.
4. Con ejecutor disponible, abrir la fuente del Site V1 usando su identidad exacta,
   integrar el adaptador, probar Inicio/Noticias/detalle/búsqueda/archivo/imagen y
   Tendencias sin regresiones, publicar y verificar nueva versión del Site.
5. Investigar reloj de radar retrasado por separado sin reconstruir la captación.
6. Actualizar periódicamente ESTE registro y después conciliar la memoria maestra
   conservando su ID y el control de versión; no crear otra memoria maestra.

## Último ajuste de consumo en reposo

El despachador de imágenes consulta un preview de solo lectura en el proceso
persistente y NO lanza hijos cuando no hay imágenes elegibles. Evita releer todos
los registros desde dos procesos nuevos cada30s cuando la cola está vacía.
Se mantiene la recuperación de leases caducadas y el máximo global de dos puestos.
Nueva regresión: preview no escribe, excluye imagen ya reservada y detecta lease
caducada. Repetir CI del paquete antes de recomendar la última instalación.

## Evidencia y planificación anteriores (histórico de este trabajo)

# Noticias V2 — registro de continuación

## Encargo vigente — 16/11/2026

Memoria maestra leída: versión 313, identidad libfile_c244fcbdb29c8191a1d37f82a7ba3aa5.
La actualización a v313 se realizó en el otro chat: queda superada la nota antigua
que decía que la memoria seguía en v312.

Objetivo autorizado:
1. Automatización editorial FIFO de Pendientes a Elaboradas, tres puestos,
   una conversación nueva por noticia y cierre propio verificado.
2. Consumidor independiente de imágenes de Elaboradas, una conversación por imagen,
   original real, hash y asociación por ID/revisión; fallo visible con I.
3. Paridad de botones con Tendencias, con acciones reales y persistentes.
4. PUB traslada de Elaboradas a Archivo; no equivale a enviar automáticamente a X.
5. El site V1 mostrará Noticias V2 siguiendo la integración existente de Tendencias.
6. Actualizar este registro al guardar cada bloque y tras sus pruebas/despliegue.

Plan de trabajo:
- Auditar los contratos actuales, acciones de Tendencias, integración pública y
  estado de despliegue. Conservar todos los procesos/datos que ya funcionan.
- Implementar estado y acciones Noticias (Archivo/PUB, revisión, imágenes y marcas)
  con control de revisión y pruebas de regresión.
- Reutilizar el transporte y recuperación probados para el consumidor independiente
  de imágenes; preparar instalador/activación Windows sin interrumpir tareas activas.
- Conectar interfaz y proyección V1; probar contratos, identidad, concurrencia,
  original raster y regresión Tendencias antes del despliegue.
- Separar código/CI/despliegue verificados de instalación/ejecución real en PC.
  No se dispone de acceso remoto al Windows: requerirá ejecutar el instalador
  y comprobar su salida; no afirmar tareas habilitadas sin evidencia.

Estado inicial comprobado:
- Rama feature/ttactualidad-v2-clean: 948a0583878cceb99448722408adc8e2c9c17571.
- Alcaraz recuperada en READY; último estado verificado 61 pendientes/0 activas/1 lista.
- Editorial automático ya implementado y probado, instalación de la corrección
  de confirmación y activación local aún sin confirmar.
- Consumidor de imágenes Noticias y acciones de ficha todavía pendientes.
- UI inicial compacta/desplegable y botón I ya desplegados.
- Baseline AGENTS.md: conservar tendencias, Chrome compartido, SeLoRecordamos,
  publicaciones y archivos; exigir CI completo antes de recomendar instalación.

## Implementación guardada — validación pendiente

Preparados: news_workflow_v2.py (decisiones CAS, revisión nueva, leases de imágenes),
news_images_v2.py (chat nuevo, original raster, cierre propio antes de asociar),
acciones D1 separadas de Tendencias, botones Noticias y feed público de Noticias V2.
PUB archiva sin envío a X; RE/RE-X preservan el registro previo.
La automatización editorial existente se integra con las decisiones nuevas.
Se añade CI Linux/Windows de regresión. Aún no desplegado ni instalado.
Pendientes inmediatos: revisar resultados CI, completar pruebas de API/concurrencia,
instalador conjunto y conexión del Site V1. Site V1 identificado: proyecto
appgprj_6ae4dcf7d7488191a574e5b649e67370, versión97, público.
Su fuente no es el repositorio europapress-rss: no confundir un feed nuevo con
el despliegue del Site. El acceso al entorno de edición del Site sigue limitado.

## Validación intermedia y paquete Windows

Primer commit de producto 6e2afe3ccf64094a1f519a33da568f868451d839.
CI 43964533430: 207 pruebas Python PASS en Linux; detectó una regresión de lectura
en la API cuando no existe D1 configurado. Corregida conservando la lectura anterior;
las escrituras siguen fallando explícitamente sin almacenamiento.
Se añadieron pruebas con SQLite real para PUB/RE-X/R/visibilidad/PU/idempotencia,
validación del PNG completo (CRC, IDAT descomprimido, filtros, tamaño y dimensiones),
y pruebas del ciclo de imagen con cierre antes de persistir y sin reenvío incierto.
Actualización conjunta Windows preparada con drenaje cooperativo exclusivo Noticias,
editorial3 e imágenes2 independientes. Aún NO se ha entregado como validada.
Site V1 v97 sigue sin modificar: fuente en git.chatgpt-team.site requiere ejecución
Git local, ausente en este entorno. No volcar credenciales a GitHub ni fingir despliegue.

## Pruebas completas del segundo bloque

Commit 05dc6811849a31d447f472802bebba7a25605843.
Run43965223064 SUCCESS en Linux y Windows: 210 pruebas Python,105 Node,
compilación y parseo de todos los instaladores PowerShell.
No afirmar instalación Windows por estas pruebas en runners.
Se amplía QA de navegador para comprobar botones y transición PUB a Archivo.
Se prepara adaptador documentado para Site V1; permanece pendiente aplicarlo
en su fuente independiente (este chat no dispone de transporte Git local).
El despliegue del Worker privado será el siguiente paso después de estas pruebas;
conservará D1, secretos, bindings y cron existentes.

## Preparación de despliegue

Se mantiene el control de acceso privado de acciones y originales; el feed de lectura
público está separado. Se limita el feed a30 fichas para respetar subrequests de Worker.
El latido de imagen se limita a45s para no escribir en GitHub en cada sondeo DOM.
Se añade comprobación de latido y de rutas privadas.
El despliegue vuelve a probar Windows, Node, Python y navegador antes de Wrangler.
Una comprobación posterior exigirá health.news_actions y feed público real.
No hay envío automático a X, ni cambios en el Site V1 independiente.

## Ajuste del CI editorial anterior

La batería nueva del commit f8e66e2fd99bddb6293141e1c399edf595948303 pasó
(run43965885993). El CI editorial anterior detectó que SU checkout disperso no
incluía los cuatro módulos de imagen añadidos al instalador. Se corrige el inventario
del workflow y su dependencia Pillow; no se modifica ni debilita la prueba del
paquete descargado. El gate Windows del despliegue ya había superado ese paquete
con el inventario completo. Despliegue en curso run43966001174; todavía no confirmado.

## Privacidad de las instrucciones editoriales

Las pistas RE-X y controles del consumidor se sirven por /api/news-worker-controls,
autenticando el token GitHub del propietario contra api.github.com/user (ID7257052).
El token se mantiene solo en memoria y nunca se guarda ni se registra.
El feed público solo incluye noticias y preferencias visibles; no contiene pistas.
Se añaden pruebas de rechazo sin credencial/otra identidad y acceso del propietario.
Esta corrección exige actualizar conjuntamente el Worker y el paquete Windows.

## Primer despliegue confirmado

Run43966001174 SUCCESS. Worker versión3136e41e-0ef8-4853-aac7-2c289b067246.
106 pruebas Node,62 Python de imagen/tendencias/noticias y navegador PASS,
incluida transición PUB a Archivo en fixture efímera, sin tocar noticias reales.
Bindings, secretos, D1 y cron conservados. Feed público real verificado con1 noticia.
Cola real:61 pendientes/0 activos/1 elaborada; radar aún19:11:32Z.
CI editorial anterior corregido: run43966205102 SUCCESS (Windows/Linux/preview real).
La siguiente versión añade controles privados del propietario, aún desplegándose
en run43966604710. El paquete Windows incorpora relanzamiento cada3min con
IgnoreNew/locks para recuperarse de salidas del daemon, sin duplicar chats.

## Último ajuste del consumidor

Se evita volver a leer y procesar por separado cada decisión histórica ya aplicada:
un snapshot identifica acciones completadas y revisiones caducadas antes del bucle.
Prueba de100 recibos ya completados: una sola lectura, cero nuevas escrituras.
Este ajuste preserva la cola automática y evita aumentar peticiones con el histórico.
Windows: piloto editorial y piloto de imagen siguen pendientes de ejecución local.
La versión nueva de controles privados continúa su despliegue antes de entregar
el comando conjunto. Site V1 v97 sigue pendiente de edición independiente.

## Evidencia previa conservada

# News V2: recovery checkpoint after master v312

Updated 16 November 2026, after confirmed original-response recovery.
The master remains libfile_c244fcbdb29c8191a1d37f82a7ba3aa5, version 312.
This operational continuation note must be reconciled into that same document.

## Original Alcaraz pilot recovered and verified

Job ttn2-0e0e7c7ebd494a7a753590d9-r1-editorial is now ready, phase done,
with no lease or problem. Original command: news-bfc6017515a34ca09d010afdd74a1d96.
Original local journal: 0e90ad3bc3f84f79ab222b762a1a7d70.
The user supplied the existing original chat response and local journal proof:
sent=true, captured=false, cleanup_verified=true, original error
NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND. The response was recovered without
opening ChatGPT, sending another message, regenerating, or enabling publication.

Code commit aa69a0482abd16c7dd821e13e09addce9fc1d6d8 adds a fenced
recover_capture operation and six recovery tests. Exact command, original journal,
cleanup proof, answer hash, global three-slot capacity, immutable READY and
idempotent replay are enforced. Recovery run 43960209171 passed 197 tests,
validated the supplied reply, and persisted/read back the real record successfully.
The full editorial check run 43960209128 also succeeded on Linux and Windows,
with installer checks and the real read-only FIFO preview.
Record origin commit: 786dc47f91e0a077d7361703386e0392f760b9b2.
Final READY transition commit: 15634eef945ab27374c2f9a10858d742645d82d4.
Record: v2/ttittulares/records/ttn2-0e0e7c7ebd494a7a753590d9/r1.json
Tweet length: 243 characters. Queue verified: 61 pending, 0 active, 1 ready.
The original send_intent prepared_at remains 2026-11-16T20:51:18Z;
submitted/captured audit times record recovery observation, not a new send.

## Consumer robustness and remaining local handoff

Commit 78714553e4f621bcb403919348b5546c8a285fc2 previously passed 191 tests on
Linux and Windows, installer syntax checks and read-only real FIFO preview
(run 43956595706). It checks exact ID/revision/command across owned browser pages,
uses a bounded localized user/assistant transcript fallback when role DOM is absent,
rejects conflicting matching chats, and never sends in its confirmation loop.
Future ambiguous attempts retain their private profile and local page diagnostics
after their own processes close. Private URLs are not written to GitHub.
No local installation of this confirmation fix is confirmed yet.

Next: run the updated Install-News-Editorial-V2.ps1 on Windows. It downloads a
hash-verified fixed branch snapshot, runs checks, and pilots the next pending story.
It enables the three-worker scheduler only after the pilot validates and its own
Chrome cleanup is confirmed. Do not reset or requeue the recovered Alcaraz job.

## Image incident reporting and V1 retirement confirmed

The I button is deployed (Cloudflare fc2a7992-f8e1-4cff-bbf8-62f1ff786b02).
The user confirmed Update-V2-ImageIncidents.ps1 installed reporting for NEW jobs:
TT_V2_IMAGE_INCIDENT_REPORTING_COMMIT=577734d2bccc3eb2ac58e2c0b61b70c469a2c1a0
Backup: C:\Users\I052279\AppData\Local\TTActualidadV2\Backup-Image-Incidents-20261116-221559-346
Chrome tasks and running jobs were unchanged. No live new image failure has yet
been independently observed. News image generation and persistent Archive remain
future work.

V1 watchdog selective retirement is installed and reloaded (PID 40148),
backup C:\TTiTTulares\Backup-Watchdog-V1-20261116-213443-189.
Shared Chrome 9223, supervisor and SeLoRecordamos remain intentionally available.
Do not stop their Chrome merely because it remains open.

Radar freshness remains unverified: latest observed capture was
2026-11-16T19:11:32Z. A configured timer alone does not prove current ingestion.

## Master document limitation

The execution runtime is unavailable. Repository changes and checks use GitHub
Actions. The native master document cannot currently be replaced because its
replacement API requires a real local file. Do not claim a new master version.
Reconcile this checkpoint into the same master with version checking when file
execution becomes available.
