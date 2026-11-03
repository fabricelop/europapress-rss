# Listas tiene prioridad sobre las imágenes

La transición editorial se acredita con el texto validado de la revisión vigente
en `ttittulares/prepared.json` o la explicación en el registro de tendencias.
Una imagen ausente, en generación, pendiente de aprobación o rechazada no impide
Listas. Los ACK de imágenes y el antiguo envío Telegram no prueban texto READY.

El radar y Redacción solicitan el editor dedicado tras persistir el encargo.
La recuperación ligera comprueba cada cinco minutos la cola autoritativa y las
reelaboraciones pendientes. Tras cinco minutos sin ejecución solicita el mismo
editor. No vuelve a lanzar mientras haya RUNNING fresco o un encargo reciente.
Reintenta cada quince minutos; después de tres intentos espacia a una hora y
mantiene el aviso de ejecutor sin respuesta, sin abandonar definitivamente el caso.
El registro `telegram/editorial-run-guard.json` conserva la evidencia de solicitudes,
esperas, ejecución y errores. Su nombre es histórico: no se envía nada a Telegram.

Cada revisión y decisión terminal se comprueba antes de tratar el texto. Los
RUNTRACE editados sobre comentarios antiguos se leen por fecha de actualización,
evitando confundir la ausencia en la última página con un editor parado.
El workflow de recuperación solo descarga scripts y JSON; excluye el histórico de
imágenes. No escribe READY, no redacta automáticamente y no aprueba imágenes.

Si el PC está apagado, la sesión ChatGPT falla o Actions no dispone de ejecutor,
se mantiene la incidencia y los reintentos; eso no equivale a contenido elaborado.
La recuperación termina únicamente al comprobar el texto real o una decisión
terminal de esa revisión. Los resultados tardíos no sobrescriben textos vigentes.
