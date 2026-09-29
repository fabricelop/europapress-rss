# Bandeja Tremending

Estado independiente de TTiTTulares para todas las entradas nuevas de
`https://www.publico.es/tremending/`.

- `items.json` es acumulativo: ninguna entrada pendiente o pospuesta caduca.
- `update_tremending.py` recorre las páginas recientes y una página histórica
  rotatoria para recuperar omisiones, deduplica por URL canónica y extrae solo
  los embeds de X que pertenecen al cuerpo del artículo.
- `capture_tweet.mjs` captura el embed oficial elegido con Playwright. Si X no
  permite renderizarlo, genera una tarjeta marcada de forma visible como
  «REPRODUCCIÓN GRÁFICA DEL TEXTO».
- Las imágenes se guardan en `ttittulares/tremending-images/` y se propagan a
  una noticia en elaboración o ya preparada sin bloquear su redacción.

La elección de destino, tuit, tono y enfoque pertenece al usuario. El sistema
no ordena ni preselecciona tuits por su posición política.
