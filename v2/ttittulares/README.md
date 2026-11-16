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

**Disponibilidad live pendiente de comprobar en el run de preview de este paso.** El workflow manual de GitHub Actions permite comprobar disponibilidad real y presentar la telemetría sin crear estado de radar. Tampoco hay scheduler, persistencia automática del radar, creación de jobs editoriales ejecutables, worker de imágenes ni página Noticias operativa en esta carpeta.

Todo se mantiene en la rama feature/ttactualidad-v2-clean. No importar automáticamente el backlog V1. No escribir en main ni en rutas V1. No publicar en X, Instagram o Telegram.


## Paso 3C — preview integrado y plan de persistencia

`radar_snapshot_v2.py` une descarga e ingesta y prepara los documentos separados
para snapshots, salud, índice, eventos elegibles y jobs editoriales pendientes.
No escribe GitHub ni activa consumidores. La entrada `documents` debe contener
el estado V2 completo leído en un único commit; un error de lectura nunca se
puede sustituir por `{}`. El modo `--live` simula deliberadamente un almacén vacío.

- Prima el estado de `news/*` y `jobs/editorial/*` sobre candidatos antiguos.
- No reabre decisiones terminales ni sobrescribe leases, intentos o resultados.
- Conserva READY anteriores al abrir una revisión material y prepara un job nuevo.
- La cola se reconstruye de los jobs individuales y la revisión actual.
- Cada plan declara hashes por fichero y exige readback íntegro mediante
  `verify_readback`. Esto es preparación/verificación, **todavía no un escritor CAS**.
- `prompt:null` identifica un job pendiente sin prompt elaborado. El contrato
  exige un prompt y su hash reales desde `send_intent`; no se inventa una huella.
- Snapshots con el mismo tiempo/URLs pero distinto contenido o salud tienen una
  huella distinta. Las capturas no almacenan artículos completos.

Prueba offline:

```bash
python -m unittest v2.ttittulares.test_contract_examples v2.ttittulares.test_radar_ingest_v2 v2.ttittulares.test_source_fetch_v2 v2.ttittulares.test_radar_snapshot_v2
```

Requiere `jsonschema==4.23.0` para la validación real de los documentos nuevos.
Son 71 pruebas (8 de contrato, 28 de núcleo, 16 de descarga y 19 de snapshots).
La suite de contrato detectó y corrigió un dato de ejemplo: 169 caracteres,
no 170, sin cambiar el texto ni relajar el test.

El workflow `ttittulares-v2-snapshot-preview.yml` realiza una prueba de lectura
real al modificar ese mismo workflow en la rama V2 o bajo petición manual.
No tiene cron, credenciales de escritura ni persistencia de datos de noticias.
Su resumen distingue disponibilidad de fuentes de validez del código.

**Siguiente paso:** escritor GitHub de un solo commit atómico con CAS, lectura
completa fijada a commit, revalidación JIT y readback de todos los hashes; luego
un primer snapshot V2 persistido y verificado. Después se conectará el consumidor
ChatGPT efímero. No hay aún un radar autónomo ni noticias elaboradas por V2.
