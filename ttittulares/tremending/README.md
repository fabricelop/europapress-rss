# Bandeja Tremending

Tremending es una **bandeja de lectura** independiente dentro de TTiTTulares para las entradas nuevas de
`https://www.publico.es/tremending/`.

- La frontera de captura actual es **30/09/2026 00:00 Europe/Madrid** (`2026-09-29T22:00:00Z`).
- `update_tremending.py` revisa las primeras 8 páginas, deduplica por URL canónica y extrae los embeds de X del cuerpo del artículo.
- La app muestra el artículo y sus tuits para lectura. **No se selecciona ningún tuit y Tremending no envía contenido a TTiTTulares ni a TTendencias.**
- La antigua captura de tuits está desactivada y su workflow queda como no-op manual.
- **Borrar** elimina físicamente la entrada de `items.json` y conserva su URL en `scan.seen_urls`, de modo que el recolector no la reintroduce después.
- Si una entrada todavía no pudo recuperar sus tuits, permanece en la bandeja para que el recolector vuelva a intentarlo.

No hay estados editoriales de enviado/pospuesto/seleccionado en el flujo vigente.
