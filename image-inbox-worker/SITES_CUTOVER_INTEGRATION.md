# Integración del filtro editorial real — bandeja privada TTActualidad

**Objetivo confirmado el 7 de noviembre de 2026:** la bandeja debe mostrar
TODAS las imágenes **pendientes de decisión** que pertenezcan a uno de estos
dos grupos, sin límite de fecha y sin máximo de imágenes:

1. **Tendencias**: episodio (ID + revisión) entre las 30 tendencias del Top 30
   vigente, **sin imagen IA ya asignada**. La imagen asignada se comprueba
   contra el catálogo IA y texto editorial de ese episodio; no basta con
   comparar un nombre o una posición en el ranking.
2. **Noticias**: episodio (ID + revisión) actualmente en **Listas**, según
   `ttittulares/prepared.json` y sus decisiones terminales. Haber entrado en
   Listas antes del 6 de noviembre no lo excluye.

No hay más condiciones de visibilidad por edad, fecha de creación, máximo 20,
ni deduplicación por episodio que suprima imágenes distintas pendientes.
Se excluyen solo elementos que ya no estén en esos conjuntos editoriales
o que hayan sido aprobados/rechazados; **no se eliminan sus originales**.

## UI y paginación

El servidor puede devolver páginas de 100 para no agotar memoria ni red. Es
un tamaño de transporte, NO un límite de la bandeja; la APP recorre
`hasMore`/`nextCursor` hasta obtener todas las candidatas elegibles.
Revisar el resultado después de cada decisión. La UI sigue comprobando
el SHA-256 del PNG original antes de aprobar y no publica automáticamente.

## Backend real

Destino: `https://ttactualidad.rainyraven22.chatgpt.site`,
proyecto Sites `appgprj_6ae4dcf7d7488191a574e5b649e67370`.

**La implementación de este repositorio es una referencia y NO despliega
ChatGPT Sites.** Los endpoints reales
`/api/image-inbox/v1/images`, `/ingest` y `/:id/decision`
deben recibir estos mismos cambios dentro del proyecto Sites autorizado.
No fusionar solo la APP declarando que el Site se ha reparado.

El receptor Windows mantiene los metadatos planos existentes:
`project, editorialId, revision, commandId, editorialText, editorialAt,
title, episodeFingerprint, rasterSHA256`. La fecha sigue formando parte de
la huella del episodio para verificar los bytes, pero **no se compara
con ningún corte temporal para la elegibilidad**.

La ingestión de una imagen se admite si su episodio pertenece a los dos
grupos actuales. La identidad editorial, revisión y texto deben seguir
coincidiendo antes de aprobar y antes de publicar. El servidor conserva D1/R2,
originales, decisiones, autorización de editor y el flujo manual existente.

## Pruebas de aceptación

- Noticia que continúa en Listas desde octubre: imagen pendiente visible aunque
  su `editorialAt` sea anterior al 6 de noviembre.
- Noticia publicada o retirada de Listas: desaparece de pendientes; original
  conservado.
- Tendencia en Top 30 sin imagen IA asignada: pendiente visible; al salir
  del Top 30, ya no es elegible.
- Tendencia con imagen IA verificada en catálogo: su pendiente no aparece.
- Más de 100 candidatas elegibles: la APP recorre páginas y muestra todas,
  sin límite de 20 ni de fecha.
- Imágenes aprobadas/rechazadas permanecen decididas y no reaparecen;
  ninguna imagen se aprueba, publica o regenera automáticamente.
- Top 30 o Listas no disponibles: mostrar error; nunca utilizar una lista
  sin filtrar o una caché vieja como si estuviera verificada.

No se alteran X, Telegram, Instagram, las relaciones entre noticias y
tendencias, ni el borrado de Listas.
