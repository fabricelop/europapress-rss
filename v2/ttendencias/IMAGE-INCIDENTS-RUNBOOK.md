# Incidencias de imagen en la ficha V2

El botón I aparece exclusivamente si existe un fallo registrado para la revisión
editorial visible. Abrirlo solicita el detalle por una ruta privada y no genera
ni reintenta imágenes. Se conserva el texto listo aunque falle su imagen.

Tendencias guarda `image_incident` en su ledger con ID, revisión, hash del texto,
comando, fecha y causa de una lista cerrada. Las excepciones desconocidas tienen
un mensaje genérico; no se publican errores crudos, URLs de chat o credenciales.
Se verifica CAS/readback y se respeta una imagen guardada o intento más nuevo.
El Top30 proyecta solo la disponibilidad del botón, sin detalles privados.

La web necesita desplegar estos cambios y el PC necesita la versión actualizada
del trabajador. `Update-V2-ImageIncidents.ps1` cambia solo image_worker_v2.py y
web_top30_v2.py, con copia, hash y sintaxis verificados; rechaza reemplazar una
versión local desconocida o un trabajador de imagen que siga en curso. No para
Chrome, tareas, daemon ni trabajos activos. Afecta a los siguientes procesos
individuales de imagen; no importa los fallos históricos de diarios locales.

Noticias ofrece el mismo detalle sobre un job de imagen tipado, por ID/revisión
y hash del registro READY. Una noticia sin imagen o sin job no es un fallo.
Su consumidor de imágenes todavía debe construirse; no se simulan incidencias.

El detalle se vuelve a validar en el servidor al pulsar I: si cambió revisión,
se guardó la imagen o hay un reintento vigente, no se muestra el error anterior.
