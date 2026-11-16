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
