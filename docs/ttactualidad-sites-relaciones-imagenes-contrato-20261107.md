# TTActualidad — contrato pendiente de integración en el Site privado (7-XI-2026)

**Ámbito:** proteger las funciones existentes de Listas, aprobaciones, relaciones y Buffer. El código GitHub iOS de PR #333 NO despliega el Site de ChatGPT. Este documento es la especificación de integración y pruebas E2E; no es una implementación operativa en producción.

## 1. Relaciones persistentes por identificadores ya existentes

**Fallo observado:** el histórico de GitHub expone `id`, `revision`, título, texto y fecha, pero no `episodeFingerprint`. El servicio privado `/api/editorial-relations/v1/snapshot` no suministra ese fingerprint de muchas noticias antiguas. La app no debe presentar como guardado algo que solo está marcado localmente.

**Contrato de corrección en el servicio actual** (sin un segundo registro de asociaciones):
- Extender el `/v1/snapshot` **existente** con todos los episodios consultables de los últimos siete días, incluso si ya no figuran en Listas; mantener su identidad editorial y relaciones anteriores en el almacenamiento persistente original. Las relaciones confirmadas permanecen cuando una tendencia deja el Top30.
- En `POST /v1/decisions` conservar autorización GitHub y el esquema de `commandId` idempotente. Aceptar `expectedNews: {id, revision}` y `expectedTrend: {id, revision}`, con `episodeFingerprint` opcional como comprobación adicional si se envía; **resolver internamente y validar** ambas entidades y sus revisiones vigentes/históricas. No exigir al usuario la huella opaca de noticias antiguas.
- Rechazar con 409 una identidad ambigua, inexistente o incompatible; nunca relacionar por similitud textual o solo por nombre. Permitir `link`, `unlink` y `dismiss` preservando semántica de bloqueos y recibos actuales. En caso `link`, devolver un recibo real `relationId` no vacío y `state=linked`; confirmar al releer el snapshot persistente.
- Adaptar después el cliente iOS para utilizar este contrato flexible **solo cuando el servidor lo admita**, evitando que siga deshabilitando Guardar por fingerprint vacío. Las casillas se cambian localmente y `Guardar relaciones` envía una única tanda, sin una petición por toque; tras guardar, `asociadas/encontradas` muestra solo asociaciones confirmadas.
- Criterios E2E en iPhone: Koldo, La Séptima, Núcleo Nacional y cualquier tendencia Top30; hasta 5 coincidencias de noticias de 7 días, incluidas archivadas; guardar; cerrar y reabrir; verificar persistencia en Confirmadas; retirar noticia de Listas o dejar que tendencia abandone Top30; comprobar que la asociación subsiste.

## 2. Bandeja privada de imágenes sin fecha ni tope arbitrario

**Situación:** PR #323 contiene una referencia Worker NO desplegada con `NEWS_CUTOVER_ISO=2026-11-06T08:43:00Z` y 20 candidatos por página; la app build79/80 además ocultaba candidatos. PR #333 elimina los filtros de iOS y pagina el contrato si el servidor lo proporciona; el Site real debe aplicar el alcance correcto al consultar y recibir originales.

- Conservar autorización privada, identificación exacta de episodio, `rasterSHA256`, original PNG verificado y decisiones manuales `approve/reject` con recibos. No aprobar imágenes por lote automáticamente.
- Respuesta `GET /v1/images?limit=20[&before=CURSOR]`: `{items, hasMore, nextCursor}` con páginas estables, orden descendente y cursor opaco. **20 es tamaño de página, no máximo de resultados**. Nunca truncar total pendiente ni filtrar por una fecha de noviembre.
- `ttendencias`: solo episodios exactos del Top30 vigente que todavía no tengan IA aprobada/asignada. `ttittulares`: solo episodios actualmente READY/en Listas, de cualquier antigüedad, sin IA aprobada/asignada.
- Elegir solo última candidata por episodio; si esta ya fue aprobada o rechazada, no resucitar una imagen anterior como pendiente. Validar que cada original y decisión corresponden exactamente a `project,id,revision,sha256`.
- Al aprobar, comprobar que la imagen exacta existe/verificó en Site y en el catálogo de la app; al rechazar, excluir de futuras páginas. Mostrar total real paginado y error distinguible si no se puede verificar la fuente.

## 3. Publicador X con medio exacto y cierre de Listas

- Prioridad ya implementada en `pilot/ttactualidad_buffer_publish.py`: **IA pública aprobada con URL y SHA256 verificables para ID/revisión/texto exactos** → foto archivo asignada → texto si ninguna foto es publicable.
- Una imagen creada en un chat **no cuenta como IA disponible para Buffer** hasta que esté asociada y verificada por el flujo editorial autorizado. No sustituir una imagen por otra por parecido, no saltar aprobación.
- Ocultar provisionalmente la ficha al pulsar «Publicar directo · Buffer», restaurar si se verifica fallo/no publicación; si `sent` X y cierre aún no confirmado, seguir conciliando sin reenvío. Solo cierre de Listas confirmado mediante recibo GitHub `applied/already_applied` del episodio y decisión.
- Nunca republicar los eventos `b547e584c4e7:r0` (#AgropopularRetinta) ni `a75e99a5ae99:r0` (#FelizSábado) para corregir la fotografía: ya constan en Buffer `sent`.

## 4. No regresión y despliegue

Mantener sin cambios las cuentas X, presupuestos de API, autenticación GitHub, botones de retirar y desestimar, redacción, catálogo de archivo, Live Activity, aprobaciones manuales, Top30 y demás funciones. Una prueba estática o una IPA compilada NO demuestra funcionamiento E2E del Site privado o instalación de iPhone. No fusionar esta rama a producción ni cambiar Site sin probar primero operaciones reales idempotentes, recibos, 401/403/409, consultas paginadas y continuidad al cerrar/abrir.
