# TTiTTulares V2

Reconstrucción aislada del motor de noticias para la web privada TTActualidad V2.

## Documentación y módulos

- [Auditoría de contratos V1](V1-CONTRACTS-AUDIT.md): qué conservar y qué sustituir.
- [Contrato de datos y arquitectura](DATA-CONTRACT.md): IDs, revisiones, jobs, estados, Chrome efímero, imágenes, decisiones y recibos.
- [Schemas JSON](schemas/contract.schema.json): ocho documentos, con cada definición en $defs.
- [Ejemplos sintéticos](examples/sample-bundle.json): objetos enlazados por event_id/revision.
- [Catálogo de fuentes](source_catalog_v2.json): 19 generales/16 familias, 5 deportivas y 3 de descubrimiento.
- [Descargador aislado](source_fetch_v2.py): GET HTTPS, allowlist de hosts, 27 fuentes, fallbacks secuenciales por fuente y hasta 8 fuentes en paralelo.
- [Motor puro de radar](radar_ingest_v2.py): normalización, filtros, agrupación, quorum, TTL e identidad/material updates.
- [Pruebas del radar](test_radar_ingest_v2.py): 28 regresiones del núcleo.
- [Pruebas de descarga](test_source_fetch_v2.py): 16 pruebas offline de parseo, fallbacks, procedencia de fechas, telemetría y paralelismo.
- [Prueba de fuentes reales](../../.github/workflows/ttittulares-v2-live-source-smoke.yml): ejecución manual, solo lectura, sin persistencia.

## Estado

**Pasos 1–2 completados. Paso 3A (núcleo puro) y paso 3B (adaptadores de descarga): implementados y validados en CI.** La suite conjunta tiene 44 pruebas y pasó en la ejecución GitHub Actions 43915856958.

El adaptador puede realizar lecturas HTTPS mediante `python -m v2.ttittulares.source_fetch_v2 --live`. Los fallbacks de una fuente conservan su misma identidad/familia; nunca se convierten en votos adicionales. El descargador limita la concurrencia, el tamaño de respuesta y el tiempo por petición; Cadena SER requiere fechas de artículos del editor dentro de 12 horas para considerarse fresca, y no confía en fechas de agregadores. Un `published_at` JSON solo se conserva cuando su procedencia editorial está identificada explícitamente.

**Aún no se ha ejecutado una pasada live contra las 27 fuentes.** El workflow manual de GitHub Actions permite comprobar disponibilidad real y presentar la telemetría sin crear estado de radar. Tampoco hay scheduler, persistencia automática del radar, creación de jobs editoriales ejecutables, worker de imágenes ni página Noticias operativa en esta carpeta.

Todo se mantiene en la rama feature/ttactualidad-v2-clean. No importar automáticamente el backlog V1. No escribir en main ni en rutas V1. No publicar en X, Instagram o Telegram.