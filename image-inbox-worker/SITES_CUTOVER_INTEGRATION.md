# Integración en el Site real — bandeja privada limitada (6-XI-2026)

**Destino real**: `https://ttactualidad.rainyraven22.chatgpt.site`, proyecto Next.js
`appgprj_6ae4dcf7d7488191a574e5b649e67370`.

**Este repositorio no despliega ChatGPT Sites**. El código del Worker es una
referencia verificable, no una sustitución de los endpoints del Site ni un
permiso para alterar su portada. No desplegar sin editor autorizado del Site.

## Contrato obligatorio para las tres capas

- El usuario no quiere revisar las ~500 imágenes antiguas. Son históricas:
  mantener PNG originales y decisiones; **no migrarlas todas a la lista visible**,
  rechazarlas en masa, aprobarlas, republicarlas ni regenerarlas.
- Tendencias elegibles: **solo** la identidad editorial (`editorial_id`,
  `revision`) de una entrada explicada del **Top 30 vigente**, obtenida de
  `trends/site-top30-current.json` en `main`. Nuevas tendencias se incorporan
  automáticamente cuando llegan al Top 30 con identidad confirmada. Si sale
  del Top 30 deja de aparecer en la bandeja, sin perder el original.
- Noticias elegibles: fecha **original** del episodio
  `editorialAt >= 2026-11-06T08:43:00.000Z` (09:43 CET); una entrega tardía
  no convierte noticias anteriores en actuales.
- Máximo **20 visibles por consulta**, orden descendente por fecha de
  recepción y desempate por ID, con cursor para páginas posteriores si el
  cliente lo solicita. Si el usuario decide sobre la versión más reciente de
  un episodio, ninguna versión anterior de ese mismo ID/revisión reaparece.
- La comprobación de autorización Github OAuth, las huellas SHA de los bytes
  originales, la comparación de ID/revisión/episodio en decisión y el flujo
  editorial de aprobación manual siguen intactos.
- En caso de indisponibilidad del Top30, fail-closed con error claro y
  reintento; no mostrar la cola sin filtrar como fallback.
- **El Site solo muestra las imágenes ya aprobadas**. No crear allí
  controles de selección, aprobación, rechazo ni subida. No tocar portada,
  publicaciones, X, Instagram, Telegram o Live Activity.

## Compatibilidad con el receptor Windows ya instalado

El PC envía `POST /api/image-inbox/v1/images/ingest` con
`Content-Type: multipart/form-data`, campo `image` PNG y campo
`metadata` que es un JSON de **campos planos**:

```json
{
  "project": "ttendencias",
  "editorialId": "ID_DE_EJEMPLO",
  "revision": 0,
  "commandId": "tr-img-encargo",
  "editorialText": "Texto exacto",
  "editorialAt": "2026-11-06T08:44:00Z",
  "title": "Título de ejemplo",
  "episodeFingerprint": "SHA256 del JSON canónico con fecha",
  "rasterSHA256": "SHA256 del PNG real"
}
```

La huella del receptor es SHA256(UTF8(JSON.stringify(
`{project,editorialId,revision,editorialText,editorialAt}`)),
**incluyendo la fecha original**. El prototipo anterior, incompatible,
aceptaba `{identity:{...}}` y no incluía la fecha en la huella. La referencia
de `src/index.mjs` se ha adaptado para aceptar ambas variantes verificadas;
el Site real deberá conservar el contrato plano ya operativo para no romper
las 321 confirmaciones acumuladas `RECEIVED_pending`.

## Modelo y consultas

1. Persistir `editorial_at` en cada nueva imagen. Si ya existe una columna
   equivalente en el Site, **reutilizarla**; no ejecutar la migración D1 del
   prototipo sobre una base Next.js diferente.
2. `GET /api/image-inbox/v1/images`: autenticar al editor; filtrar por
   Top30 actual o fecha editorial original de noticias; elegir una sola
   imagen candidata más reciente por episodio **antes** de seleccionar solo
   `pending`; devolver máximo 20 y cursor si procede.
3. `POST .../ingest`: rechazar noticias antiguas y tendencias fuera del
   Top30 con error específico, sin impedir la entrega futura de casos
   elegibles; respuestas 201 `pending` o 200 `existing` (idempotentes).
   No forzar estado `pending` al reenviar una imagen rechazada.
4. `POST .../:id/decision`: validar identidad exacta; el rechazo debe
   funcionar incluso si falla la descarga del PNG; la aprobación requiere
   PNG verificado. No reabrir una imagen antigua del mismo episodio.
5. Para aprobación, revalidar la identidad con la fuente editorial
   autoritativa actual: tendencias pueden haber salido de Listas pero siguen
   en el Top30; las noticias pueden haber salido de `prepared.json`, así
   que debe usarse un registro duradero **con texto e identidad exactos**.
   No sustituirlo por coincidencia de título, fecha aproximada ni rank.

## Pruebas E2E que deben pasar en el Site real

- Con centenares de registros antiguos aún almacenados, la APP recibe entre
  0 y 20 elementos, ninguno de una noticia anterior al corte.
- Tendencia explicada vigente del Top30: ingestion, consulta, descarga con
  SHA, aprobar/rechazar, refrescar y comprobar estado persistido.
- Imagen de noticia editorial **nueva**: el timestamp original, no
  `created_at` de ingreso, determina elegibilidad.
- Una tendencia que abandona el Top30 no reaparece por caché ni ocupa plaza.
- Reenvío de imagen ya decidida devuelve `existing` pero no resucita en
  pendientes.
- Simular Top30 inaccesible, OAuth inválido, revision stale, PNG manipulado,
  500 registros antiguos y error 503 del Site. En todos los casos, no
  publicaciones ni aprobaciones automáticas.
- Confirmar que portada y flujos X/Telegram/IG permanecen intactos.

**Estado al redactar**: el receptor Windows corregido está en GitHub
`main`, pero requiere actualización en el PC. PR #323 es referencia de
backend (no desplegada en ChatGPT Sites). PR #325 es iOS Build75 de prueba;
no instalar como solución definitiva hasta que el endpoint real suministre
`editorialAt` y aplique el filtro anterior.
