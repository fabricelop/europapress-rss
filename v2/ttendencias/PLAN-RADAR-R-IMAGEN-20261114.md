# TTActualidad V2 — Radar, botón R y piloto de imagen

Fecha: 2026-11-14. Estado: diseño seguro y primer cambio del contrato editorial, NO desplegado.

## Requisitos confirmados

- Web de consulta actual: https://fabricelop.github.io/europapress-rss/v2/
- URL obligatoria **al final de cada tuit**: https://ttactualidad.rainyraven22.chatgpt.site/
- Texto publicable en X de **280 caracteres ponderados como máximo**, URL=23. No confundir el informe de fuentes/estados con el tuit. El informe editorial extenso queda separado y no es publicable.
- Antes de la primera tendencia: `Radar · DD/MM/YYYY HH:mm (hora peninsular)`, procedente de `history.observed_at` y enlace https://getdaytrends.com/es/spain/. No sustituir por hora de render, de publicación en GitHub o de revisión editorial. Si captura antigua, marcarla desactualizada.
- Botón `R` discreto en **cada** tendencia: solicita nueva investigación desde cero, incluso si está pendiente, explicada, READY, publicada, desestimada o en incidencia.

## Diseño del botón R (NO activado)

La página GitHub Pages es pública y estática: NO poner un token GitHub ni un endpoint de escritura sin autenticación en JavaScript.

El botón R debe pedir confirmación y abrir una operación autenticada mediante backend/Worker. Contrato propuesto:

`POST /v2/trends/{trend_id}/reevaluate` con `expected_revision`, `idempotency_key` y sesión autorizada. Respuesta: `accepted`, `conflict` o `deferred_active_worker`.

1. Leer el estado de la rama V2, verificar ID y revisión y exigir autorización.
2. Guardar snapshot inmutable de la revisión anterior: texto, fuentes, imágenes, estado, URL de chat, historial y fecha.
3. Si hay una conversación activa o `send_intent` pendiente, NO sobrescribirla ni lanzar otro chat. Registrar petición `reevaluation_requested` para resolver cuando el trabajador termine o entre en recuperación.
4. Si no hay trabajo activo, incrementar revisión, crear episodio independiente `review_pending`, limpiar **solo** los datos derivados de la nueva revisión; conservar el historial. No eliminar publicaciones ya realizadas ni alterar sus referencias.
5. Invalidar de forma segura respuestas/imágenes tardías de la revisión anterior mediante CAS y token de episodio.
6. Proyectar estado `Pendiente de reevaluación` y ejecutar el consumidor habitual sin duplicados.
7. Idempotencia: dos clics sobre la misma revisión no crean dos trabajos.

No usar `GET` con efectos secundarios. No permitir que un visitante anónimo reevalúe tendencias.

## Piloto de texto + imagen en la misma conversación

Una sola tendencia elegida por el editor, sin afectar a las otras 29:

1. Capturar y persistir primero el tuit y el informe contrastado.
2. En el mismo chat, solicitar una imagen de prueba.
3. Descargar el fichero real y verificar MIME, tamaño, hash SHA-256 y que corresponde al ID/revisión/episodio.
4. Asociar mediante GitHub CAS y verificar relectura; solo entonces marcar imagen lista.
5. Si falla la imagen, conservar texto; registrar fallo y cerrar navegador. No bloquear Top30 ni publicar nada.

**No activar en producción** hasta probar el flujo completo de imagen y la compatibilidad del navegador con la descarga original.

## Estado del código en esta rama

- `editorial_run_v2.py`: prompt de tuit delimitado `TUIT_INICIO/TUIT_FIN`, URL canónica y límite de X; metadatos y fuentes fuera del bloque.
- `web_top30_v2.py`: campos `radar_source`, `radar_last_retrieved_at`, `tweet_text`, `tweet_status`. Un tuit anterior sin delimitadores queda sin `tweet_text`; no inventar uno a partir de la ficha extensa.
- **Pendiente**: localizar y editar la fuente de la página pública, crear el endpoint autenticado R, tests de conteo X y piloto gráfico.

La rama `feature/ttactualidad-v2-clean` continúa sin estos cambios. No fusionar antes de pruebas y aprobación.
