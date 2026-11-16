# TTiTTulares V2

Reconstrucción aislada del motor de noticias para la web privada TTActualidad V2.

## Documentación y módulos

- [Auditoría de contratos V1](V1-CONTRACTS-AUDIT.md): qué conservar y qué sustituir.
- [Contrato de datos y arquitectura](DATA-CONTRACT.md): IDs, revisiones, jobs, estados, Chrome efímero, imágenes, decisiones y recibos.
- [Schemas JSON](schemas/contract.schema.json): ocho documentos, con cada definición en $defs.
- [Ejemplos sintéticos](examples/sample-bundle.json): objetos enlazados por event_id/revision.
- [Catálogo de fuentes](source_catalog_v2.json): 19 generales/16 familias, 5 deportivas y 3 de descubrimiento.
- [Descargador aislado](source_fetch_v2.py): HTTP GET por fuente, allowlist HTTPS, recuperación secuencial por fuente y concurrencia global limitada.
- [Motor puro de radar](radar_ingest_v2.py): normalización, filtros, agrupación, quorum, TTL e identidad/material updates.
- [Pruebas de radar](test_radar_ingest_v2.py): 28 regresiones del núcleo puro.
- [Pruebas de descarga](test_source_fetch_v2.py): 14 pruebas offline de parseo, fallbacks, errores y paralelismo.

## Estado

**Pasos 1–2 completados. Paso 3A (núcleo puro): validado en CI. Paso 3B (adaptadores de descarga): implementado y pendiente de validación CI.**

El descargador puede realizar lecturas HTTPS de las fuentes mediante `python -m v2.ttittulares.source_fetch_v2 --live`. No se ha ejecutado aún una pasada real contra las 27 fuentes. Las pruebas no usan red y simulan todos los resultados. Todavía no hay scheduler, servicio residente ni persistencia automática del resultado; el guardado opcional de una captura manual queda restringido a `v2/ttittulares/state/`. No hay worker editorial, worker de imágenes ni página Noticias operativa en esta carpeta.

Todo se mantiene en la rama feature/ttactualidad-v2-clean. No importar automáticamente el backlog V1. No escribir en main ni en rutas V1. No publicar en X, Instagram o Telegram.