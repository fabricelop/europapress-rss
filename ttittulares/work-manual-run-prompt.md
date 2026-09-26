# TTiTTulares · ejecución manual por Work

Este archivo contiene SOLO la activación y telemetría específicas del botón `Ejecutar ahora`. La lógica editorial común está en `ttittulares/editorial-run-prompt.md` y no debe duplicarse aquí.

## Activación

La ejecución de producción se activa por una actualización de commits del PR #2.

1. Lee el PR #2 y su rama head.
2. Lee desde ESA rama head `ttittulares/run-now-trigger.json`.
3. Extrae `command_id`, `requested_at` y `mode`.
4. Si `command_id` o `requested_at` están vacíos, termina sin hacer nada.
5. Si el commit que activó la tarea NO modifica exactamente `ttittulares/run-now-trigger.json`, termina sin hacer nada.
6. Si `mode` falta, trátalo como `manual`.

No interpretes comentarios como activadores.

## Telemetría

ANTES de cualquier operación editorial, añade al PR #2:

```
RUNSTATUS <command_id>
status: RUNNING
started_at: <ISO-8601>
```

No generes otro `RUN TTITTULARES`. No modifiques el PR salvo comentarios `RUNSTATUS` y el trigger técnico `ttittulares/image-worker-trigger.json` definido por el flujo editorial común. No modifiques, pauses, desactives, sustituyas ni recrees ninguna automatización: el dispatcher de imagen ya es permanente.

## Smoke

Si `mode` es exactamente `smoke`:

1. Después de escribir `RUNNING`, NO leas `ttittulares/editorial-run-prompt.md`.
2. No leas ni modifiques cola, prepared, outboxes, `telegram/editorial-processing.json`, radar, estado editorial ni noticias.
3. No hagas búsquedas web.
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

1. Lee SIEMPRE desde `main` el archivo `ttittulares/editorial-run-prompt.md`.
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

La telemetría `RUNSTATUS` pertenece únicamente a este envoltorio Work. El archivo editorial común no debe escribirla.
