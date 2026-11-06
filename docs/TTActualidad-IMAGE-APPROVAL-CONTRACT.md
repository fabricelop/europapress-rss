# TTActualidad — contrato de aprobación única de imágenes (02/11/2026)

**Estado: componente de lógica aislado, NO integración ni despliegue.** La app pública, el Sites de producción, el PC Windows y los catálogos actuales NO se modifican por este commit. El módulo puro y sus pruebas constituyen la base de validación de la nueva función; no procesan fotografías reales ni exponen un endpoint.

## Decisión editorial vigente

Las imágenes nuevas se **reciben únicamente en una bandeja privada de la APP**, con original exacto y texto/ficha correspondiente. Ninguna imagen nueva se sube directamente a la web ni aparece en una ficha visible durante la recepción. La bandeja ofrece **solo «Aprobar» y «Rechazar»**:

- **Aprobar:** autoriza asociar **ese raster original** a **esa ficha y episodio/revisión**. Un publicador autorizado y verificable comprueba de nuevo identidad + SHA del raster y lo hace visible en **APP y web**. Una confirmación previa no sirve si cambia el original, revisión, episodio o encargo. No existe «Solo app» ni un botón «Publicar en web» independiente.
- **Rechazar:** quita **solo ese candidato** de la bandeja privada. No elimina el original almacenado, no borra imágenes ya aprobadas, no edita fichas ni catálogos, no inicia regeneración y no publica nada.

No se reactiva Telegram. La APP de referencia es **build59** de `feature/ttactualidad-ios-build59-links-no-card`, no el iOS antiguo de `main`. El Sites de producción es `appgprj_6ae4dcf7d7488191a574e5b649e67370` v38; V2 sigue reservado a pruebas. Mantener el bloqueo web de Jesús de Miguel, Owono y Andorra: no deshacer la política v38 al añadir el control general.

## Datos obligatorios

`project` (`ttendencias` / `ttittulares`), `editorialId` (ID de tendencia o event_id de noticia), `revision`, `episodeFingerprint` SHA-256 del acontecimiento/contexto, `commandId` del encargo y `rasterSHA256` de los bytes reales. La identidad se firma por digest de estos seis datos. **ID + revisión no son suficientes**: un ID puede reutilizarse con r0 para otro hecho. La URL o vista previa de Images no acredita identidad ni bytes.

## Contrato de ejecución pendiente

1. **PC receptor:** reanudar exclusivamente captura/retorno privado (no la asociación automática pausada en PR270), verificar el raster por bytes, conservar fuente, registrar candidato por clave única en almacenamiento privado y mantener material inaccesible al público.
2. **API privada autenticada:** listar pendientes y servir previews, verificar identidad editorial vigente contra `main`, almacenar decisión editor con idempotencia y protección de concurrencia; rechazar solicitudes sin autenticación. El repositorio GitHub público no debe utilizarse como almacén de imágenes inéditas ni contener URLs privadas reutilizables.
3. **APP build59+:** añadir «Imágenes pendientes» con miniatura, texto, ficha y fecha, y exactamente «Aprobar» / «Rechazar». No colocar un selector de visibilidad adicional. Mostrar fallo cuando la revisión cambió, y dejar las funciones actuales intactas.
4. **Publicador:** solo a partir de `approved_awaiting_publication`, verificar otra vez SHA/identidad y escribir ambas asociaciones (APP/Sites) con recibos auditables. No declarar aplicada la aprobación hasta verificar **ambos** destinos; si uno falla, conservar intención pendiente y reintentar sin duplicar. El flag de web debe ser `default-deny` para toda imagen nueva. Evitar que los trabajos históricos de asociación salten este control.
5. **Sites producción:** implementar guardia general de aprobación en rutas, tarjetas, ampliaciones, SEO y API, además de las tres exclusiones de v38. Una aprobación antigua no libera una imagen nueva. El Site no es el repositorio editorial GitHub.

## Criterios de aceptación

- Nueva imagen: solo bandeja privada, cero visibilidad APP/web antes de aprobar.
- Aprobar con identidad y SHA exactos: aparece en ficha correspondiente en APP **y** web y deja la bandeja; reintentos son idempotentes.
- Rechazar: desaparece de bandeja y no modifica catálogos/imagen original.
- Raster distinto, revisión distinta, nuevo episodio r0, command_id distinto o actor no autorizado: no se publica.
- Los originales, fotos de archivo, decisiones, publicaciones previas, enlaces X, agrupación, radar, edición, Instagram y exclusiones v38 permanecen intactos.
- Prueba de extremo a extremo con PC y APP reales más Site producción antes de anunciar operativa. Sin acceso a Sites/PC no se puede acreditar este resultado.

## Implementación parcial en este commit

`shared/image-approval-policy.cjs` define normalización, identidad estable, decisión y puerta de publicación verificable de forma pura. `tests/image-approval-policy.test.cjs` cubre aprobación sin escrituras, rechazo sin borrado, hashes cambiados, episodio r0 reutilizado, revisión obsoleta, idempotencia y conflictos. No se conecta todavía a servicios: intencionadamente evita colar imágenes en producción o crear una bandeja que fingiría funcionar.

## Extensión — puerta editorial doble y traspaso privado (02/11/2026)

El contrato se concreta en el PR274, sin publicarlo. Antes de registrar `approve`,
el Worker comprueba que el texto EXACTO de `prepared.json` en GitHub `main`
para el ID/revisión sigue coincidiendo. El importador calcula la huella del
episodio a partir de identidad+texto completo, no de nombres o parecido visual.
Antes de entregar el PNG aprobado a un publicador separado se vuelve a comprobar
`main` y el SHA de los bytes. El traspaso privado exige un secreto de publicador
y una credencial Github de lectura independientes de los del receptor/APP.
`reject` solo elimina la fila del buzón visible, sin borrar original.

Ninguna ruta hace pública una imagen, reanuda los WebImages anteriores, elimina
fotos de archivo ni escribe Sites. Se sigue necesitando un publicador que valide
por tercera vez inmediatamente antes de publicar en los dos catálogos y confirme
que las dos fichas muestran el mismo raster aprobado. Sin ese puente la aprobación
NO equivale a publicación.