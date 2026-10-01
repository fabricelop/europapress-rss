# Bandeja Tremending

Estado independiente de TTiTTulares para las entradas nuevas de
`https://www.publico.es/tremending/`.

- La frontera de captura actual es **30/09/2026 00:00 Europe/Madrid**
  (`2026-09-29T22:00:00Z`). No se reintroduce el histórico anterior al corte.
- `items.json` es acumulativo: ninguna entrada pendiente, enviada, descartada o
  pospuesta caduca.
- `update_tremending.py` revisa las primeras 8 páginas en cada pasada para
  disponer de margen anti-omisiones, deduplica por URL canónica y extrae solo los
  embeds de X que pertenecen al cuerpo del artículo.
- Una URL nueva **no se añade a `seen_urls` por el mero hecho de aparecer en una
  página**. Solo se marca como vista cuando se ha incorporado a la bandeja o
  cuando su fecha ha sido verificada como anterior a la frontera de captura. Si
  falla la lectura o no se puede verificar la fecha, queda pendiente de reintento.
- `capture_tweet.mjs` captura el embed oficial elegido con Playwright. Si X no
  permite renderizarlo, genera una tarjeta marcada de forma visible como
  «REPRODUCCIÓN GRÁFICA DEL TEXTO».
- Las imágenes se guardan en `ttittulares/tremending-images/` y se propagan a
  una noticia en elaboración o ya preparada sin bloquear su redacción.

La elección de destino, tuit, tono y enfoque pertenece al usuario. El sistema
no ordena ni preselecciona tuits por su posición política.
