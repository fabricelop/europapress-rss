# TTendencias · ejecución manual por Work

Este archivo contiene SOLO la activación y telemetría específicas del botón `Ejecutar ahora`. La lógica editorial común está en `trends/editorial-run-prompt.md` y no debe duplicarse aquí.

**Ámbito exclusivo:** este envoltorio se usa únicamente cuando una automatización Work realmente conectada recibe el evento `synchronize` del PR #7. No debe utilizarse como sustituto de la orden «Ejecuta TTendencias» recibida directamente en un chat o enviada por `Ejecutar.js` desde el PC. En esos casos, ejecutar `trends/editorial-run-prompt.md` en el chat, sin crear un commit-trigger que nadie consuma. El marcador `WORK COMMIT TRIGGER READY` del PR es una marca de configuración, NO una confirmación de que haya un ejecutor activo. Nunca considerar una solicitud `REQUESTED` como una pasada iniciada ni terminada.


## Activación

La ejecución de producción se activa por una actualización de commits del PR #7.

1. Lee el PR #7 y su rama head.
2. Lee desde ESA rama head `trends/run-now-trigger.json`.
3. Extrae `command_id`, `requested_at` y `mode`.
4. Si `command_id` o `requested_at` están vacíos, termina sin hacer nada.
5. Si el commit que activó la tarea NO modifica exactamente `trends/run-now-trigger.json`, termina sin hacer nada.
6. Si `mode` falta, trátalo como `manual`.

No interpretes comentarios como activadores.

## Telemetría

El panel web usa UN SOLO comentario vivo en el PR #7 con formato exacto:

`TTENDENCIAS_RUNTRACE_V1`
`<json-una-linea>`

Usa `command_id` como `run_id`, `source:"manual"` y localiza el comentario creado por el API del botón con ese mismo run_id. Si no existe, créalo. Conserva su comment_id y ACTUALIZA SIEMPRE ESE MISMO COMENTARIO durante toda la ejecución; no crees uno por fase.

Campos mínimos: `version:1,run_id,command_id,source,status,phase,current,total,trend_id,title,requested_at,started_at,updated_at,finished_at,incident_count,incidents,summary,message`.

Al arrancar: `status:"RUNNING",phase:"preparing"`. Antes de investigar cada tendencia: `phase:"investigating"`; antes de redactar: `drafting`; al generar y puntuar candidatos internos del remate: `remate_selection`; antes de imagegen: `image_generating`; al revisar raster: `image_checking`; al persistir el único outbox ready con imagen: `persisting`; al comprobar aplicación: `verifying`; al terminar: `closing`. Usa `current` 1..N y `total` N con `trend_id` y `title` actuales. Cuando el contrato común use selección por estrellas, conserva también `ratings_snapshot` y `remate_selections` en el mismo RUNTRACE; no crees un segundo comentario para ello.

Cada fallo no bloqueante incrementa `incident_count` y añade a `incidents` un objeto breve `{at,phase,trend_id,title,reason}` sin secretos. Mantén como máximo las 8 incidencias más recientes. Un fallo individual no cambia RUNNING si se puede continuar.

Al terminar actualiza ese mismo comentario a `status:"DONE"`, `finished_at`, `phase:"closing"` y `summary:{trends_processed,trends_ready,trends_problematic,images_ready,incidents}`. Si un fallo global impide continuar, usa `status:"ERROR"`, `finished_at` y mensaje técnico breve.

La telemetría `TTENDENCIAS_RUNTRACE_V1` es solo informativa y NUNCA activa una ejecución.

ANTES de cualquier operación editorial, añade al PR #7:

```
RUNSTATUS <command_id>
status: RUNNING
started_at: <ISO-8601>
```

No generes otro comando. No modifiques el PR salvo comentarios `RUNSTATUS`. No modifiques, pauses, desactives, sustituyas ni recrees ninguna automatización.

## Smoke

Si `mode` es exactamente `smoke`:

1. Después de escribir `RUNNING`, NO leas `trends/editorial-run-prompt.md`.
2. No leas ni modifiques cola, prepared, outboxes, requests, recent, config, imágenes ni ningún estado editorial.
3. No hagas búsquedas web ni generes imágenes.
4. Escribe inmediatamente:

```
RUNSTATUS <command_id>
status: DONE
finished_at: <ISO-8601>
message: Smoke test OK
```

5. Termina la ejecución.

Si `mode` es distinto de `manual` o `smoke`, escribe `ERROR` con una causa breve y termina sin tocar estado editorial.

## Ejecución manual real

Solo si `mode` es `manual`:

1. Lee SIEMPRE desde `main` `trends/editorial-run-prompt.md`.
2. Ejecuta ÍNTEGRAMENTE sus instrucciones como fuente única de verdad del flujo editorial.
3. No sustituyas esas instrucciones por una copia memorizada ni por este archivo.
4. Al terminar correctamente, incluso si la cola estaba vacía, escribe:

```
RUNSTATUS <command_id>
status: DONE
finished_at: <ISO-8601>
message: <resumen breve y factual de lo realizado>
```

5. Si un fallo fatal impide completar la ejecución, escribe:

```
RUNSTATUS <command_id>
status: ERROR
finished_at: <ISO-8601>
message: <causa concreta y breve>
```

La telemetría `RUNSTATUS` pertenece únicamente a este envoltorio Work.
