# TTActualidad V2 — control móvil sin Telegram

## Estado

- Código de interfaz, Worker, aplicador y pruebas: **rama aislada** `pilot/ttactualidad-direct-decisions-20261015`.
- App oficial `main/docs/index.html`: **sin cambios**.
- Producción: **sin órdenes desde el Worker**. `ACTION_MODE` no está habilitado.
- El Worker ya existe; el nuevo instalador `pilot/Update-TTActualidad-UI-v2.ps1` solo actualiza el piloto.
- No se añade ningún proceso Chrome ni nueva tarea programada en Windows.

## Lectura (sin Cloudflare)

La web consulta los estados existentes publicados en GitHub:

- TTiTTulares: `ttittulares/prepared.json`, `ttittulares/status.json`, `ttittulares/decisions.json`.
- TTendencias: `trends/telegram-image-deliveries.json`, `trends/editorial-queue.json`, `trends/requests.json` y decisiones.
- Las fotografías existentes se visualizan por URL; no hay generación de nuevas imágenes ni imágenes alojadas en Cloudflare.

## Acciones

- **Publicar en X** abre `twitter.com/intent/tweet` y no da por publicada la noticia.
- **Ya publicada** marca el elemento para retirarlo de Listas, cuando el aplicador esté habilitado.
- **Borrar** retira de Listas cuando GitHub confirme el cambio, sin pasar por Telegram.
- **Desestimar** solo si la noticia sigue en elaboración con la revisión esperada.
- Si no se decide nada, siguen funcionando automáticamente los procesos actuales. No se crea otro temporizador.

En el piloto `/api/decision` admite `prepare`, `discard`, `deleted` y `published`, con registros idempotentes por `project:event_id`. Si no se ha autorizado la integración, devuelve `state: pilot_only`, **no** afirma que se haya borrado.

## Activación futura, separada y explícita

Para que funcionen las órdenes en producción hay que revisar los cambios con un lote controlado y entonces:

1. Publicar en `main` el aplicador `pilot/apply-ttactualidad-action.py` y el workflow `.github/workflows/ttactualidad-direct-actions.yml`; pruebas y revisión de coherencia primero.
2. Crear un token GitHub de grano fino **solo para** `fabricelop/europapress-rss`, con permiso Contents: read/write para `repository_dispatch`; no pegarlo en chats ni archivos.
3. Guardarlo exclusivamente como secreto de Cloudflare `GH_DISPATCH_TOKEN`; poner `ACTION_MODE=github_dispatch` en el Worker y volver a desplegar exclusivamente el Worker pertinente.
4. Verificar una acción real controlada con un ID existente y revision; comprobar en GitHub el nuevo estado y que TTActualidad refleja el cierre. Un `HTTP 204` de GitHub solo confirma que aceptó el evento, no que el cambio se aplicó.
5. Pasar entonces la interfaz aprobada a GitHub Pages. Conservar rollback quitando `ACTION_MODE`.

Nunca mezclar los archivos de la rama piloto con la rama principal de golpe; activar mediante cambios selectivos revisados.

## Coste y rendimiento

- Una solicitud al Worker únicamente cuando el usuario pulsa o comprueba la conexión; **sin polling** del Worker en segundo plano.
- Dos operaciones KV como máximo por orden normal (consulta+escritura); listar la bandeja solo cuando se pida.
- GitHub recibe a lo sumo un evento de dispatch por nueva orden en el modo activo, no por cada actualización visual.
- Ningún listener de Chrome adicional y ninguna función Vercel.

## Riesgos que obligan a pruebas antes del corte

- Cambio de revisión durante la elaboración.
- Cierre concurrente entre Telegram (heredado) y nuevo aplicador.
- Elementos compartidos entre publicaciones de TTendencias.
- Condiciones de carrera de GitHub Actions al actualizar `main`.
- Límite de 100 registros por listado KV de esta primera versión y eventual consistencia en lectura.
- Estados `published`/ `deleted` deben confirmarse en los JSON autoritativos, nunca por simple respuesta del Worker.
