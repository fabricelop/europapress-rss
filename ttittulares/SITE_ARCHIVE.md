# TTActualidad V2 — archivo acumulativo propuesto

Esta propuesta no modifica el Site original ni las colas, decisiones, Telegram o publicadores. No debe fusionarse sin aprobación.

Se incluyen 397 acontecimientos / 403 revisiones de Listas entre el 26/10 y el 01/11 de 2026 (Europe/Madrid), recuperados examinando las 1.232 versiones de `prepared.json` del intervalo, sin errores de descarga. Cada revisión contiene la referencia al commit que demuestra su presencia. Las eliminaciones posteriores de Listas no se interpretan como retiradas de la web. No se añaden artículos de feeds ni entradas `treated` sin evidencia.

El workflow propuesto ejecuta una tarea cada 15 minutos, con paginación, reintentos y cursor solapado. Recorre cada snapshot comprometido en GitHub desde el cursor y acumula por `(event_id, revision)`, por lo que recupera entradas aunque la cola ya esté vacía al ejecutarse. El histórico no se borra al retirar entradas. Los fallos de snapshot impiden avanzar el cursor. Los fallos de imágenes conservan el texto.

Limitación: no puede capturar un estado READY que nunca haya sido comprometido en GitHub. Acciones programadas pueden retrasarse; esto afecta la frescura, no elimina los commits históricos. La captura se verifica tras fusionar mediante un evento de prueba aislado que aparezca y desaparezca en dos snapshots. No se afirma que esté activa antes de esa prueba.

La V2 lee `site-archive.json` como catálogo de origen y mantiene una copia indexada en su propia D1. Las consultas del navegador se paginan a 12 noticias. Las fechas iniciales se preservan durante las actualizaciones de imagen. Un mismo evento muestra su revisión mayor; se conservan las anteriores. La V2 permanece privada y no instala analítica externa.

Las 397 noticias recuperadas carecían de IA validada en las versiones examinadas y las fotografías figuraban con derechos `unverified`: se muestra un recurso neutro propio. El importador admite únicamente IA generada con asociación exacta, hash y archivo verificables. La incorporación automática de otras fotografías autorizadas requerirá documentar su licencia, sin confiar en un simple estado `ready`.

El archivo acumulativo debe conservarse durante cualquier migración. No existe retirada automática del histórico por las decisiones sociales `deleted` o `published`; las retiradas web requieren una acción editorial explícita y separada.
