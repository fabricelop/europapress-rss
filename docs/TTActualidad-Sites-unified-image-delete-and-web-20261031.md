# TTActualidad / TTendencias Site — contrato de supresión conjunta IA y ajustes de web

Estado: pendiente de habilitar operación de borrado en el proyecto ChatGPT Sites. **No activar un botón que afirme éxito sin confirmar los dos destinos.**

## Botón futuro de iPhone: «Suprimir imagen IA»
- Visible solamente para una tendencia con `siteImageURL` real. La foto de archivo no se borra.
- Confirmación: «Se suprimirá la imagen IA de la ficha de TTendencias Site y de TTActualidad. La foto de archivo permanecerá».
- Solicitud autenticada, idempotente, únicamente para `project_id`, `target_id`, `scope=editorial`, `revision`, `explained_at`, `explanation` y `sha256` literal del PNG.
- Revalidar en el Site la ficha y el SHA actuales antes de borrar. Si cambia identidad/imagen, responder `conflict`; **jamás borrar por nombre/posición**.
- El servidor del Site debe ofrecer `remove_trend_image` o endpoint autorizado equivalente que elimine la asociación de la ficha, invalide la URL de publicación y devuelva `status: missing` para la misma identidad; también verificar acceso HTTP público, no basta ocultar la etiqueta HTML.
- Solo después del recibo del Site, borrar **únicamente** la entrada (target_id, revision, explained_at, explanation, sha256) de `trends/site-ai-images.json` mediante GitHub API con SHA y reintento de conflictos. Mantener el resto del catálogo intacto.
- Si falla el paso Site, no suprimir el registro de la app y mostrar «Site pendiente»; si falla GitHub después de un Site correcto, la app debe reconciliar y mostrar «App pendiente», y no volver a subir/regenerar el PNG.
- Confirmación final SOLO tras verificar Site sin asociación + manifiesto sin entrada. Registro de auditoría y estado de la solicitud para reintentos, conservando la imagen de archivo.
- No exponer credenciales de Site/GitHub en HTML ni transmitirlas al clipboard; usar la autenticación del backend.
- El conector disponible actualmente solo permite `inspect_top30_images`, `attach_trend_image` y `verify_trend_image`. **No hay operación de borrado. Por eso la acción no está habilitada aún.**

## Cambios solicitados para la web ChatGPT Sites existente
- Eliminar botones «Copiar prompt» y «Publicar en X», manteniendo la web solo como consulta.
- El buscador de tendencias será compacto y se ubicará inmediatamente antes de Top 30.
- Compactar tarjetas en PC: cabecera de una fila con puesto, nombre, edad, estado; texto y fuente en sección desplegable sin grandes huecos; imagen IA no deberá desplazar excesivamente.
- Tratar explicaciones vencidas igual que en app: no mostrar un texto viejo solo porque el término reaparece en Top 30 (ej.: Funes); en su lugar «Pendiente».
- Al habilitar supresión, web y app deben consumir la misma señal de eliminación y aplicar la misma identidad.

La web está en el proyecto ChatGPT Sites `appgprj_6ae4dcf7d7488191a574e5b649e67370`. Ninguno de los cambios web de este documento queda publicado hasta contar con una herramienta de edición/despliegue del Site original y con su capacidad de borrar imágenes.
