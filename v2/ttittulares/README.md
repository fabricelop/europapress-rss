# TTiTTulares V2

Reconstrucción aislada del motor de noticias para la web privada TTActualidad V2.

## Documentación y módulos

- [Auditoría de contratos V1](V1-CONTRACTS-AUDIT.md): qué conservar y qué sustituir.
- [Contrato de datos y arquitectura](DATA-CONTRACT.md): IDs, revisiones, jobs, estados, Chrome efímero, imágenes, decisiones y recibos.
- [Schemas JSON](schemas/contract.schema.json): ocho documentos, con cada definición en $defs.
- [Ejemplos sintéticos](examples/sample-bundle.json): objetos enlazados por event_id/revision.
- [Catálogo de fuentes](source_catalog_v2.json): 19 generales/16 familias, 5 deportivas y 3 de descubrimiento.
- [Motor puro de radar](radar_ingest_v2.py): normalización, filtros, agrupación, quorum, TTL e identidad/material updates.
- [Pruebas del radar](test_radar_ingest_v2.py): 28 pruebas sin red, ChatGPT, Chrome, Windows ni persistencia.

## Estado

**Paso 1: auditoría V1 completada. Paso 2: contrato de datos completado. Paso 3: núcleo puro de radar/ingesta implementado; validación CI en curso.**

El radar todavía no descarga feeds, no tiene scheduler, no escribe a GitHub y no crea jobs editoriales ejecutables. La siguiente fase debe añadir adaptadores de lectura/fetch y persistencia aislada, después de que estas pruebas pasen. No hay worker editorial, worker de imágenes, página Noticias ni automatización productiva en esta carpeta.

Todo se mantiene en la rama feature/ttactualidad-v2-clean. No importar automáticamente el backlog V1. No escribir en main ni en rutas V1. No publicar en X, Instagram o Telegram.