# TTiTTulares · ejecución manual por Work

Este procedimiento es la fuente operativa de la tarea de Work activada por comentarios del PR #2.

## Activación y telemetría

La tarea SOLO debe continuar si el comentario que la activó empieza exactamente por `RUN TTITTULARES`.
Extrae `command_id`, `requested_at` y `mode`. Si `mode` falta, trátalo como `manual`.

ANTES de cualquier otra operación, añade al mismo PR:

```
RUNSTATUS <command_id>
status: RUNNING
started_at: <ISO-8601>
```

Al terminar correctamente, incluso con cola vacía:

```
RUNSTATUS <command_id>
status: DONE
finished_at: <ISO-8601>
message: <resumen breve>
```

Si un fallo fatal impide completar la ejecución:

```
RUNSTATUS <command_id>
status: ERROR
finished_at: <ISO-8601>
message: <causa concreta y breve>
```

No generes otro `RUN TTITTULARES`. No modifiques el PR salvo comentarios RUNSTATUS. No modifiques, pauses, desactives, sustituyas ni recrees ninguna automatización.

## Flujo editorial

Usa el conector GitHub conectado para leer y escribir EXCLUSIVAMENTE TTiTTulares en `fabricelop/europapress-rss`, rama `main`. El conector puede estar expuesto mediante Code Mode/functions.exec: úsalo por el mecanismo disponible antes de concluir que GitHub no está accesible. GitHub es la única persistencia/estado. Web se usa para verificación actual, investigación, imágenes existentes y búsqueda de publicaciones públicas de X.

Lee SIEMPRE `ttittulares/editorial-queue.json` desde `main`. Procesa TODOS los items pendientes, del más antiguo al más reciente. Para cada item: investiga, redacta, busca candidatos de X, escribe/corrige SU outbox inmediatamente, fuerza/aplica el aplicador cuando sea necesario y verifica que el item llegó realmente a Listas antes de comenzar el siguiente. Un item difícil no bloquea los demás.

Usa todos los campos disponibles, incluidos `event_id,title,url,sources,source_count,selected_at,selection_mode,revision,rewrite_request,parent_event_id,update_context,with_image,image_mode,image_instruction`. Verifica hechos esenciales. Política/controversia: factual y neutral. Deportes: confirma estado/resultado justo antes de redactar. Si tras dos búsquedas no puedes verificar suficientemente, escribe el outbox de la misma revisión con `status:"problematic"` y `problem_reason`, y continúa.

### Redacción

Para cada item verificable genera Principal + exactamente A/B/C.

- Principal: noticia factual, `remate:""`.
- A/B/C: `remate` empieza exactamente por `🌶️ `; `text` = principal + dos saltos reales + remate.
- Nada de `\\n` visibles.
- Comprueba expresamente que CADA `text` completo mide <=280 caracteres.
- URL: `https://twitter.com/intent/tweet?text=` con el texto exacto codificado.
- Nunca humor a costa de víctimas, abusos, tragedias o sufrimiento.

Si `with_image=true`, intenta una imagen existente real y pertinente, nunca generada. Usa búsqueda específica y una segunda vía/og:image si falla la primera. Prioriza fuente oficial/primaria y luego medios fiables. Si no puedes verificar derechos usa `rights_status:"unverified"`. La ausencia final de imagen no bloquea el tuit.

### Citas de X sin API de pago

Para CADA noticia verificable busca publicaciones públicas de X sobre el mismo acontecimiento. Prueba al menos dos formulaciones, incluyendo búsquedas restringidas a x.com/twitter.com cuando ayuden.

No buscamos otra cuenta que publique la misma noticia, sino conversación ya existente a la que TTiTTulares pueda aportar el dato completo. Excluye medios/agencias/agregadores/cuentas oficiales que estén anunciando sustancialmente el mismo titular. Prioriza reacciones, preguntas, opiniones, bromas o conversación de usuarios/cuentas de nicho. Cuanto menor interacción, mejor si sigue siendo pertinente: 0–5 ideal; 6–20 muy bueno; 21–100 solo si no hay opción mejor; >100 fuertemente penalizado. No inventes URL, autor, texto ni métricas.

Guarda como máximo tres candidatos ordenados en `prepared_item.quote_candidates`, con `url,author,text_excerpt,published_at` cuando exista, `interaction_hint,reason,source_query`. Si no hay candidato suficientemente bueno, usa array vacío.

Añade siempre `prepared_item.quote_search={query,url}` como fallback manual, con búsqueda Live de X y una query corta y útil.

### Outbox y aplicación

Para `ready`, escribe inmediatamente `ttittulares/editorial-outbox/<event_id>-r<revision>.json` con `event_id,revision,status:"ready"` y `prepared_item` completo: `event_id,title,url,drafted_source_count,sources_at_draft,prepared_at,factual_summary,revision,variants,image` si existe, `quote_candidates,quote_search`.

No dupliques un outbox válido. Si el outbox de esa revisión ya existe pero es inválido o alguna variante supera 280 caracteres, corrige ESE MISMO archivo; no crees una revisión nueva.

El aplicador real es `.github/workflows/apply-ttittulares-outbox.yml`, que ejecuta `ttittulares/apply_editorial_outbox.py`. Un item `ready` NO está terminado hasta verificar en `main` simultáneamente:

1. aparece en `ttittulares/prepared.json`;
2. en `telegram/editorial-processing.json` está `READY`;
3. ya no aparece en `ttittulares/editorial-queue.json`;
4. ya no aparece en `ttittulares/status.json.processing_items` y queda reflejado en Listas/`ready_count`.

Si al comenzar hay un item cuyo outbox de esa revisión ya existe, no lo saltes. Valídalo. Si es válido pero no se aplicó, actualiza `ttittulares/apply-trigger.txt` con `event_id`, revisión y fecha/hora para disparar el aplicador; relee estado y reintenta de forma segura una vez si fuera necesario.

Al final relee SIEMPRE cola, prepared, editorial-processing y status. Para cada item tratado exige correspondencia completa entre outbox consumido, preparado presente, READY y ausencia de En elaboración.

## Robustez

- Nunca cambies ni desactives programaciones.
- Relee siempre estado fresco de `main`.
- Si una escritura falla, relee SHA y reintenta; si persiste, deja ese item pendiente y continúa.
- Nunca uses rama o PR como sustituto de `main`.
- No uses Telegram.
- No cambies radar, fuentes o umbrales.
- No despliegues Vercel.
- No proceses TTendencias ni SeLoRecordamos.
