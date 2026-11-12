# TTActualidad V2 — construcción aislada

**Rama:** `feature/ttactualidad-v2-clean`. **Estado:** paso 1 validado en vivo (Actions #43320096517); paso 2B configurado con GetDayTrends como fuente única, pendiente de validar en Actions.

## Reglas de aislamiento
- Producción `main`, workflows, Windows, Cloudflare, app, Site y publicaciones: **sin cambios**.
- Código nuevo exclusivamente en `v2/`; no se utilizan las colas, tokens ni decisiones de producción para escribir.
- Las Actions existentes programadas solo ejecutan en la rama por defecto; el nuevo CI V2 solo verifica código, sin escribir y sin cron.
- No se ejecuta `trends/update_trends.py` completo: se **reutilizan las funciones de interpretación** actuales, pero el nuevo capturador no modifica `trends/recent.json` ni `trends/editorial-queue.json`.

## Etapas
1. **Captura Top30 España:** `v2/ttendencias/capture_top30.py`; obtiene HTML de GetDayTrends y exige treinta posiciones únicas antes de entregar un JSON. Distingue `observed_at` (hora de nuestra lectura) de una observación original en X, que **no está verificada**.
2. **Diagnóstico de frescura:** `v2/ttendencias/assess_freshness.py` diferencia la edad de nuestra captura de la frescura original de X. No declara verificada una tendencia por HTTP 200, por cambio de lista ni por fecha local reciente. **Decisión del usuario (12/11/2026):** GetDayTrends será la única fuente por ahora. Si la consulta en vivo devuelve 30 posiciones válidas de España y la captura tiene hasta 20 minutos, `eligible_for_editorial=true` para el FUTURO paso 3 (todavía no conectado). No se afirma verificación directa por X. La comparación con otra fuente queda opcional, no bloqueante.
3. **Movimientos e historial V2:** `v2/ttendencias/detect_changes.py` detecta altas, salidas, cambios de puesto y regresos; asigna un `trend_id` permanente y determinista por término normalizado, sin usar fechas ni posiciones. Un regreso tras más de 24 horas fuera crea un episodio de revisión bajo el mismo ID; si la ausencia es de 24 horas o menos, conserva el episodio. El historial de identidades no se poda por antigüedad. Primera lectura = línea base sin 30 falsas noticias. No se incorpora a la cola editorial de producción.
4. Cola editorial, investigación, redacción y persistencia — **pendiente**.
5. Imágenes, decisiones, publicación y migración — **pendiente**.

## Probar (sin efectos laterales)
```sh
python3 -m unittest discover -s v2/ttendencias -p 'test_*.py' -v
python3 -m v2.ttendencias.capture_top30
```
El segundo comando realiza una **consulta de lectura** en vivo y muestra un snapshot en stdout. No genera commits ni modifica producción. La opción `--output v2/ttendencias/state/capture.json` permite guardar localmente un resultado aislado para comparación, sin envío ni automatización.

## Paso 3: contrato de estados
- Recibe solamente la captura GetDayTrends V2 aceptada en el paso 2.
- Exige tiempos monótonos, no mezcla capturas de una misma hora con contenidos distintos y es idempotente.
- `baseline` es inicialización; `entry`, `exit`, `up`, `down`, `short_return`, `reentry` son transiciones, no solicitudes editoriales.
- **Regla de identidad (usuario):** cada término mantiene SIEMPRE el mismo `trend_id` aunque desaparezca meses; `episode_token` es solo una marca técnica de revisión, nunca un ID de ficha. Una reentrada tras **más de 24 horas fuera** genera `reexplain_candidate:true` sobre ese mismo ID, sin explicar automáticamente. Una causa nueva o una explicación materialmente cambiada también podrá activar revisión en la futura etapa editorial, aunque la tendencia no haya salido. No hay reexplicaciones por cambiar de puesto ni por tener 24 horas de antigüedad sin salida observada.
- Datos locales solo en `v2/ttendencias/state/` o artefactos temporales de CI. Una sola captura prueba el arranque; para validar cambios reales hacen falta snapshots sucesivos.

## Paso 2: condiciones de aceptación
- Informar `capture_age_minutes` y marcar una captura con más de 20 minutos como `capture_expired`.
- **Nunca** confundir `observed_at` con la fecha de observación de X: `source_observed_at=null` hasta evidencia independiente.
- Guardar `freshness-report.json` solo como artefacto temporal de Actions, sin commits ni modificaciones de main.
- Aceptar GetDayTrends como única fuente según decisión del usuario, sin mostrar validación de X que no existe.
- No abrir cola editorial ni provocar efectos de producción.

## Puerta de salida del paso 1
Pruebas unitarias aprobadas, lectura en vivo con 30 posiciones y metadatos verificables. Hasta entonces no se considera E2E validado. No sustituir la fuente ni afirmar correspondencia directa con X.
