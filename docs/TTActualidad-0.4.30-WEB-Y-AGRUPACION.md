# TTActualidad 0.4.30 y sitio público —31/10/2026

iPhone: 0.4.30 build36, rama feature/ttactualidad-ios-0.4.30-agrupadas-morado, commit 9c6f4cb418514ba6b3d8c85d9a5fc96e4ef9208c. Actions https://github.com/fabricelop/europapress-rss/actions/runs/41174689744: pruebas nativas, app y Live Activity correctas. IPA comprobada: versión/build y extensión. Instalación física no acreditada.
IPA: https://chatgpt.com/library?file_id=libfile_7486dfa45114819180823c3c1e415349&account_id=personal

Morado: solo originales agrupadas de Listas; filtro y Listas conjunta. Se exige inListas/isCovered, se excluye isJointGroup. No se cambian orden, estados, fechas, publicación ni color de conjuntas/ranking.

Sitio: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/. Buscador por nombres/miembros de grupos sobre Top30 y explicaciones guardadas; incluye fuera de24h, excluye retiradas. Botón X abre borrador con explicación exacta completa; no publica ni confirma ni cuenta. La sesión la gestiona X, no puede prometerse autenticación vigente. Colores de edad reforzados en borde, fondo, número y etiqueta.

Windows: el editor cancela el paquete y pide suprimirlo. Eliminado .github/workflows/ttactualidad-windows.yml en dd25f1b344b35fa6fb302b10566f861d4ab9bcaf; cambio visual Windows de esta entrega revertido. Código histórico conservado. No suprimir listeners, bridge, Chrome ni relay del PC.

Imágenes nuevas: GP de Malasia592bc75eb909 y Poland7f69649ad704 no tenían job ni imagen; editorial_grouping_state pending. El reparador terminaba0 correctamente por el gate; agrupación activa pero sin ejecución desde03:46UTC. Los cierres GITHUB_TOKEN no desencadenaban agrupación por push y cron retrasado no la suplía. Corregido: workflow_run de cierres editoriales exitosos + despertar explícito del planificador desde reparador cuando procede; se mantienen prioridad, pause, snapshot y gate, sin generar desde Work.
Commits: f810fe3b43be934c98393863aab722f89215078a y ba72875416115dc56cc2415beed060b0e4eac1c5. Agrupación41175283850 ha persistido listas-auto-60598ef948ccc9204100 y solicitado al PC tr-1793426882192-manual. Falta observar su resultado y los jobs/raster reales antes de declarar generación completada. Comprobación horaria cancelada por el usuario; no reactivarla.


## Resultado comprobado de generación y entrega —31/10/2026

La agrupación automática listas-auto-60598ef948ccc9204100 completó su resultado a06:11UTC. GP de Malasia592bc75eb909 quedó cleared y generó el job tr-img-auto-592bc75eb909-r0-a1-1793427194201; bridgev32 confirmó lanzamiento a06:14:00Z. Existe el raster original «Vintage Photo-Finish Motorcycle Race.png», libfile_6b5909dae7cc81918d162c44974c1e48, creado06:14:41Z, 1672×941 y2705466bytes, con el comando/exposición exactos. No se generó desde Work ni se recuperó manualmente para fingir recepción. A06:20UTC el job seguía LAUNCHED, sin web_image ni upload_sha256: **generación comprobada, recepción web todavía no comprobada**.

Poland7f69649ad704 quedó covered por la agrupación publicada listas-joint-f6486e28f95ce346 «Crisis del Tribunal Constitucional de Polonia», coverage_reason already_published_same_event. No corresponde otra imagen independiente. La web resuelve esa relación explícita por ID y revisión, incluso si el texto de la original es posterior; buscador y ficha siguen la conjunta y su imagen validada. El job antiguo de la conjunta sigue LAUNCHED y main no tiene ai_image. No declarar reutilización real de una imagen inexistente en esos datos. «Polish Courtroom with Uniformed Officer.png» es de TTiTTulares tt-img-auto-f87e989a1c5c-r1-a1-1793393277422; no asignarlo a TTendencias por parecido o fecha.

La primera consulta mostró timeout de recogida a90s; después editorial-runtime mostró RUNNING y finalmente DONE/cola0 con la agrupación aplicada. No concluir que el PC sigue parado a partir del timeout inicial. Contrato y barrera de agrupación (pilot/trend_maintenance.py y listas_grouping.py) tienen los mismos hashes que antes de las modificaciones del receptor; el fallo probado era la ausencia de activación explícita del planificador tras el cierre.

Sitio público versión11, commit ea604483e57de3357cf929bc5885877fb6dfeee5. Pruebas de modelo15/15, incluidas búsqueda histórica, texto exacto del borrador X y cobertura de original por agrupación publicada. El sitio indica pendientes de agrupación antes de generar, sin afirmar recepción de una imagen aún inexistente.


### Error de red del consumidor web observado

El job nuevo de GP registró web_image.waiting / fetch failed a06:19:05Z. El raster existe pero esa recepción no está completada. Publicados f9e24c8db09dc22c9403acc289fb0c486246908a (fallback de lectura RAW al receptor existente, revalidación exacta y diagnóstico por etapa/código de red) y 14d938a04a139176b3e96bf77bf366c5a1422259 (exigir el consumidor compatible en el refresco). Pruebas del consumidor16/16 y CI Windows41176490139 correcto. No adjuntar GP manualmente para declarar éxito automático ni asumir que un deploy acredita carga física del helper o acceso a Chrome9234. La comprobación horaria permanece desactivada.


### 31/10: causa confirmada del bloqueo de recepción

A las08:53Madrid, GP de Malasia, Luka y Atocha muestran web_image.waiting con relay_version_ECONNREFUSED (últimos diagnósticos08:33–08:35Madrid). El proceso no logra conectar con el navegador9234; no es una falta de raster en esos casos. Main seguía sin ai_image en las378 fichas consultadas. Se añade selectExistingBrowser: preferir9234; si no está disponible, usar exclusivamente una pestaña temporal propia en el Chrome9223 ya activo y con una página ChatGPT. No iniciar procesos, no navegar el target fijo, no tocar TTImages ni sus sesiones. Se mantienen ID/revisión/command/texto/fecha, rechazo de imágenes ambiguas/inacabadas y validación justo antes de subir. Listener exige el helper compatible para que el actualizador existente recoja el cambio.19 pruebas locales correctas. Código preparado; falta verificar recepción real tras su distribución al PC. No reactivar seguimiento horario ni regenerar GP/Luka/Atocha ni adjuntar manualmente para simular éxito.


### Publicación y límite de comprobación de esta reparación

Publicado c50d549f6bcace2c3e9430da5dfe8b4ed9f3da7c (alternativa por navegador existente9223;19 pruebas y CI Windows41182552286/41182552303 correctos). El primer intento real posterior de GP dejó atrás ECONNREFUSED y pasó a command_not_visible a07:58:04UTC. Publicado 8ea67f158f0f2efce467f01f51e5560a5c7695d2: esperar hasta45s a la carga y distinguir capture_requires_sign_in, command_not_in_conversation y conversation_not_loaded. No asignar una imagen sin que aparezca el command_id exacto. La comprobación acotada de180s terminó sin recibo DONE. La carga física de la segunda versión y la primera recepción correcta siguen pendientes; no declarar funcionamiento automático por tests/deploy ni sustituir por backfill manual. No se ha reiniciado Chrome ni reactivado la programación de vigilancia.


### 31/10 09:20 Madrid: restaurar independencia de generación

Incidente nuevo comprobado en el receptor: Halloween1510c923e357, encargo tr-img-auto-1510c923e357-r0-a2-1793433939217, ERROR a08:11:44Z; conjunta Sprint de MotoGP en Sepang listas-joint-021a97e2e386c40f, encargo tr-img-auto-listas-joint-021a97e2e386c40f-r0-a1-1793433659009, ERROR a08:08:24Z. Ambos fallaron en el preflight antes de escribir el prompt: TTENDENCIAS_PRE_SUBMIT_FAILED, compositor no disponible60000ms, CDP timeout Runtime.evaluate. No es prueba de generación ni un mero enlace ausente. El usuario creó después las dos imágenes manualmente; no atribuirlas al bridge automático.

Se encontraron además dos acoplamientos introducidos al añadir entrega web: Start-ImageBridge exigía Ensure-WebPublisherLatest, y el bridge podía fallar antes de enviar por require/enroll o después de enviar por rememberConversation sin try/catch. **No son la causa directamente registrada de los dos errores de compositor**, pero se eliminan como bloqueos indebidos. Bridge v33 carga y registra el exportador opcional solo después del lanzamiento confirmado o en finally tras un resultado incierto. Ningún error web reenvía el prompt ni marca fallida una generación. Mismo prompt, estilos, agrupación, launcher y proceso ChatGPT Images; sin nuevo generador desde Work.

El fallback de captura v5 deja de crear pestañas temporales en9223 y solo lee una conversación ya abierta exacta;9234 conserva su vía independiente. Se difiere el arranque del consumidor si hay un bridge de imagen activo y se verifica command_id en el último turno antes de fijar URL. Esto elimina la interferencia añadida por pestañas de captura; no demuestra que fuese la causa del renderer bloqueado. Si falta9234 y se ha cerrado/reutilizado la conversación, la imagen queda pendiente y no se afirma entrega automática. No se reinicia Chrome ni se cambia TTImages.

Pruebas nuevas ejecutan el flujo real del bridge con helper ausente/fallido y comprueban envío+ACK sin fallo; comprueban también que preflight real sigue fallando sin duplicar y que un ACK incierto conserva handoff. El consumidor se prueba con navegador simulado: ninguna apertura/navegación en9223, subida con identidad exacta, rechazo al cambiar el comando y espera si la conversación no existe. Windows DPAPI verifica que una URL antigua no se guarda y que la URL probada es inmutable. Falta recepción real nueva para acreditar el ciclo completo; no usar las imágenes manuales como demostración de automatismo ni reactivar vigilancia programada.
