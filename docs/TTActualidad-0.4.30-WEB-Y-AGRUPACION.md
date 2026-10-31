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
