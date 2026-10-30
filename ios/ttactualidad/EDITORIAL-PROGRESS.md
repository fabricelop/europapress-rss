# TTActualidad 0.4.26 · Seguimiento de En elaboración

## Incidencia comprobada, 30/10/2026

El usuario veía ocho noticias en elaboración y no percibía resultado al pulsar
Solicitar procesamiento. El disparador real del iPhone sí estaba en la rama
activa del PR #2: `tt-ios-1793362478410-b1491681`, solicitado a las 12:14:38Z.
Durante la revisión se verificaron siete noticias en `prepared.json`, cerradas
entre las 12:23:35Z y las 12:24:55Z por el proceso editorial concurrente. La cola
compacta y el resumen quedaron a cero a las 12:27:20Z. Esta reparación no redactó
ni publicó esas noticias y no modificó sus decisiones.

## Causa y corrección del cliente

- La consulta periódica de 0.4.25 solo se activaba para órdenes sin comprobante
  y trabajos de agrupación de tendencias. No bastaba tener noticias aceptadas
  en elaboración: una pantalla abierta podía quedarse con el contador anterior.
- El botón escribía el trigger, pero no consultaba la cola antes ni después.
- Una cola compacta válida y vacía activaba el fallback al resumen histórico.
  Se respeta ahora ese vacío y se excluyen revisiones ya READY de En elaboración.
- Un overlay de preparar/reelaborar podía quedarse esperando ver la revisión
  intermedia en elaboración cuando ya había aparecido directamente READY. Se
  retira al llegar la revisión objetivo; READY anterior no cierra una reelaboración.

0.4.26 build32 consulta cada 60 segundos mientras haya órdenes, noticias o
tendencias en elaboración, o esté abierta esa vista. Solo actúa en primer plano.
El botón comprueba la cola, solicita el procesamiento si sigue habiendo trabajo,
consulta de nuevo y muestra el resultado real de la petición. Un fallo de lectura
no se presenta como confirmación de cola vacía. Registrar una petición no prueba
que el PC haya enviado el mensaje ni que la redacción haya terminado.

`EditorialProgressPolicyTests.swift` reproduce los ocho casos de seguimiento,
cola vacía autoritativa, revisiones ya READY y cierre de overlays. El workflow
nativo ejecuta estas pruebas junto con las siete del menú del icono.

Si una entrada sigue pendiente tras una consulta fresca, revisar su ID/revisión,
el trigger, el listener PC, el envío efectivo del mensaje y la persistencia del
outbox. El ACK histórico `run-ack.json` de octubre no confirma comandos actuales.
No repetir órdenes indefinidamente ni modificar imágenes o decisiones para
simular que una noticia se ha elaborado.
