# TTiTTulares V2

Reconstrucción aislada del motor de noticias para la web privada TTActualidad V2.


## Estado actual — paso 3D

`radar_store_v2.py` implementa lectura de todo el estado necesario fijada a un
commit y una transacción atómica GitHub con `createCommitOnBranch` y
`expectedHeadOid`. Repo y rama están fijados al entorno V2; solo escribe rutas
de radar, eventos, jobs pendientes y recibos V2. Nunca usa force ni borra archivos.

Cada operación tiene un recibo inmutable derivado del input y la hora del fetch.
La respuesta solo es éxito tras releer el commit exacto y comprobar todos los
hashes. Si se pierde la respuesta, localiza el commit del recibo y verifica sus
bytes, aunque la rama haya avanzado después. Si hay conflicto sin recibo, relee
todo y recalcula; no reutiliza un plan antiguo. Un barrido más reciente impide
sobrescribirlo con un input anterior. Un fallo de lectura no equivale a estado vacío.

La suite incluye **102 pruebas**: las 73 anteriores y 29 de persistencia/CAS,
recuperación y contrato HTTP/GraphQL. Pasaron localmente antes del commit.
El workflow `ttittulares-v2-radar-persist-once.yml` repite la suite antes de
realizar una sola lectura live y transacción; verifica también la repetición
exacta sin segundo commit. Se activa solo al cambiar ese mismo workflow en la
rama V2 o bajo ejecución manual: **sin cron ni consumidor editorial**.
La existencia del escritor no demuestra por sí sola que el snapshot real esté
persistido: comprobar su run, recibo y commit antes de declararlo operativo.

```bash
# GET solamente, sin persistencia:
python -m v2.ttittulares.radar_store_v2 --live
# Una transacción V2 y prueba de replay (requiere GITHUB_TOKEN):
python -m v2.ttittulares.radar_store_v2 --live --persist --verify-replay
```

Después de verificar el primer snapshot persistido, el siguiente paso es el
contrato/claim del worker editorial efímero y su prompt. Los jobs siguen pending,
con prompt null; ninguna ejecución de ChatGPT, READY, imagen o publicación se
activa con este paso. Mantener V1 y Windows intactos.

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

**Pasada live verificada en el run 43920629257: 27/27 fuentes recuperadas, siete mediante fallback.** El workflow manual de GitHub Actions permite comprobar disponibilidad real y presentar la telemetría sin crear estado de radar. Tampoco hay scheduler, persistencia automática del radar, creación de jobs editoriales ejecutables, worker de imágenes ni página Noticias operativa en esta carpeta.

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
Son 73 pruebas (8 de contrato, 28 de núcleo, 16 de descarga y 21 de snapshots).
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


### Rendimiento de agrupación

La primera validación a escala mostró un coste alto de recalcular normalización,
tokens y similitudes. `identity_v2.py` conserva las reglas y añade cachés LRU
acotadas (8.192 entradas de características y 16.384 pares de titulares). Los sets
públicos siguen siendo copias mutables para que ningún llamador contamine la caché.
Se prueban equivalencia de puntuaciones y aislamiento de esos valores.


### Validación final del 16/11/2026

Código validado: `74c4ddd2da3cba6cd82bc8897c81f94c9795601d`.
CI `43920629456`: 73/73 pruebas y `TTN2_RADAR_PURE_CORE=PASS`.
Preview real `43920629257`: 27 fuentes recuperadas, cero degradadas/fallidas,
siete fallbacks, 1.435 entradas recibidas, 1.401 aceptadas tras normalización,
1.015 candidatos y 26 elegibles. Preparó 57 archivos para una simulación de
almacén vacío; **no persistió ni ejecutó los 26 jobs** y no creó READY.
Lectura: 18:41 CET; fetch ~21 s y agrupación/plan ~10 s según el log del runner.
Estas cifras describen ese barrido; no garantizan disponibilidad futura ni
validación factual del contenido. La siguiente fase sigue siendo el escritor CAS.
