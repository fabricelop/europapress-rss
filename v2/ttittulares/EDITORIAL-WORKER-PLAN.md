# Contrato aceptado del consumidor de noticias V2

Decisiones del usuario, 16/11/2026. **Diseño acordado; no workers desplegados todavía.**

## Texto y cola

- Entrada automática al reunir el umbral del radar; cada `event_id`/revisión
  produce un único job pending durable. No ejecutar el listener V1 como sustituto.
- FIFO por `requested_at` (momento de entrada a Pendientes), más antiguas primero;
  desempate estable por ID. **Tres slots editoriales simultáneos.** Los primeros
  tres jobs se reclaman en ese orden; cada slot libre toma el siguiente. El orden
  de finalización puede variar: no bloquear un resultado correcto esperando otro.
- Claim exclusivo mediante CAS, lease/heartbeat y validación de noticia/revisión
  justo antes del envío. Un descarte, archivo o revisión nueva prevalece. No
  duplicar jobs ni reenviar cuando la confirmación del envío es ambigua.
- Cada noticia usa su propio chat ChatGPT y Chrome/perfil aislados; investigar,
  contrastar, redactar, capturar, cerrar recursos propios y verificar limpieza.
- Mismos criterios y exigencia editorial que tendencias: hechos contrastados,
  claridad, concisión, un único remate específico cuando proceda y sin relleno.
  Mantener el contrato de noticia de hasta 256 caracteres completos (cabe en X),
  hashtags concretos y registro de evidencias. No asignar un ranking TT# a noticias.
- Persistir READY inmutable y verificar por ID/revisión/hash. La web desplegable
  muestra exclusivamente `tweet.text`, nunca el dossier largo ni un placeholder.

## Imagen separada

Otro proceso recorre Elaboradas y crea trabajos de imagen por registro READY
exacto: `event_id` + revisión + `editorial_sha256`. Como en tendencias, un chat
nuevo de Images por trabajo, original raster, hash del archivo, asociación exacta,
readback y cierre de sus recursos. Un fallo de imagen no bloquea el texto ni
devuelve una noticia READY a pendiente. La capacidad de imágenes es independiente;
el requisito de tres slots se refiere al texto, no a tres imágenes simultáneas.

## Botones a debatir / completar

- Recomendados: RE (reelaboración), P-X (acción manual), PU (confirmación manual
  de publicada), Imagen y Archivar. Mantener RE-X —investigación en X— como opción
  secundaria cuando aporte contexto, sin confundirlo con una simple reescritura.
- Requisito explícito: **Archivar pasa de Elaboradas a Archivo**. Conserva texto,
  imagen, identidad, revisiones e historial; no equivale a publicar ni a borrar.
  Restauración explícita desde Archivo, evitando reabrir automáticamente el hecho.
- Implementar estas acciones con decisiones durables/idempotentes y readback;
  ampliar el schema y el aplicador para `archive` antes de ofrecer ese botón.
  La vista actual no debe mostrar botones que finjan realizar una acción.

## Asociación futura con V1

Conservar `event_id`, revisión y huella editorial como identidad V2. La asociación
con V1 será explícita, con referencia de origen y recibo verificable; no importar
backlog, sobrescribir publicaciones ni asociar una imagen a otra revisión. Esta
fase no publica ni escribe en V1.
