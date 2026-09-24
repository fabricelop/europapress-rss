# TTiTTulares · ejecución manual desde la app

Preparación técnica para el botón **Ejecutar ahora**. Esta rama no debe desplegarse todavía.

## Arquitectura

1. La web llama a `POST /api/ttittulares-run`.
2. El endpoint exige `TTITTULARES_RUN_SECRET` y usa el `GITHUB_TOKEN` ya empleado por el control web.
3. El endpoint añade un comentario a un PR permanente de control:
   `RUN TTITTULARES`, `command_id`, `requested_at`, `mode: manual`.
4. Una tarea ChatGPT Work activada por comentario de PR filtra únicamente comentarios cuyo cuerpo empiece exactamente por `RUN TTITTULARES`.
5. Work responde en el mismo PR con:
   - `RUNSTATUS <command_id> / status: RUNNING / started_at: ...`
   - al terminar: `status: DONE / finished_at: ...`
   - en fallo fatal: `status: ERROR / finished_at: ... / message: ...`
6. `GET /api/ttittulares-run-status` lee esos comentarios y devuelve el estado y las latencias reales.
7. La web muestra Solicitada → Ejecutándose → Terminada/Error y calcula retraso de arranque y duración.

No hay llamadas a la API de OpenAI. La ejecución la realiza ChatGPT Work con la cuota del plan del usuario.

## Variables necesarias al activar

- `GITHUB_TOKEN`: ya utilizado por la app actual.
- `TTITTULARES_RUN_PR_NUMBER`: número del PR permanente de control.
- `TTITTULARES_RUN_SECRET`: clave privada distinta del token GitHub.

La clave se solicita una vez desde la web y se guarda únicamente en `localStorage` del navegador. El endpoint rechaza peticiones sin clave correcta.

## PR permanente de control

Crear después de validar la configuración, en una rama distinta de la rama de implementación. No reutilizar un PR funcional de otro proyecto. El PR permanece abierto y no se fusiona.

## Protección contra dobles ejecuciones

El endpoint rechaza un nuevo `RUN TTITTULARES` si hubo otra solicitud en los 45 segundos anteriores.

## Activación pendiente

No crear el trigger Work hasta que haya cuota disponible. No modificar las tareas programadas `:20` y `:50`: la tarea manual es independiente.
