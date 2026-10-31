# TTActualidad 0.4.30 y sitio público —31/10/2026

iPhone: 0.4.30 build36, rama feature/ttactualidad-ios-0.4.30-agrupadas-morado, commit 9c6f4cb418514ba6b3d8c85d9a5fc96e4ef9208c. Actions https://github.com/fabricelop/europapress-rss/actions/runs/41174689744: pruebas nativas, app y Live Activity correctas. IPA comprobada: versión/build y extensión. Instalación física no acreditada.
IPA: https://chatgpt.com/library?file_id=libfile_7486dfa45114819180823c3c1e415349&account_id=personal

Morado: solo originales agrupadas de Listas; filtro y Listas conjunta. Se exige inListas/isCovered, se excluye isJointGroup. No se cambian orden, estados, fechas, publicación ni color de conjuntas/ranking.

Sitio: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/. Buscador por nombres/miembros de grupos sobre Top30 y explicaciones guardadas; incluye fuera de24h, excluye retiradas. Botón X abre borrador con explicación exacta completa; no publica ni confirma ni cuenta. La sesión la gestiona X, no puede prometerse autenticación vigente. Colores de edad reforzados en borde, fondo, número y etiqueta.

Windows: el editor cancela el paquete y pide suprimirlo. Eliminado .github/workflows/ttactualidad-windows.yml en dd25f1b344b35fa6fb302b10566f861d4ab9bcaf; cambio visual Windows de esta entrega revertido. Código histórico conservado. No suprimir listeners, bridge, Chrome ni relay del PC.

Imágenes nuevas: GP de Malasia592bc75eb909 y Poland7f69649ad704 no tenían job ni imagen; editorial_grouping_state pending. El reparador terminaba0 correctamente por el gate; agrupación activa pero sin ejecución desde03:46UTC. Los cierres GITHUB_TOKEN no desencadenaban agrupación por push y cron retrasado no la suplía. Corregido: workflow_run de cierres editoriales exitosos + despertar explícito del planificador desde reparador cuando procede; se mantienen prioridad, pause, snapshot y gate, sin generar desde Work.
Commits: f810fe3b43be934c98393863aab722f89215078a y ba72875416115dc56cc2415beed060b0e4eac1c5. Agrupación41175283850 ha persistido listas-auto-60598ef948ccc9204100 y solicitado al PC tr-1793426882192-manual. Falta observar su resultado y los jobs/raster reales antes de declarar generación completada. Comprobación horaria cancelada por el usuario; no reactivarla.
