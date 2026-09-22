# TTiTTulares · control web

Esta carpeta es independiente de TTendencias y contiene el estado de la futura app web de TTiTTulares.

## Flujo previsto

- Radar: :10 y :40 (cinco minutos antes de la redacción).
- Redacción: :15 y :45.
- Umbral editorial: 4 fuentes generales distintas.
- 3 fuentes: solo indicador de proximidad; no se redacta todavía.
- Al alcanzar 4 fuentes, la noticia queda disponible para que el siguiente pase editorial la procese automáticamente.
- Antes de redactar se mantiene la verificación editorial actual.
- Una novedad material del mismo asunto se crea como un evento/revisión nueva; no reabre la noticia anterior.
- Telegram se mantiene únicamente durante la transición. El corte final será cambiando `control-mode.json` a `web`.

## Bandeja `prepared.json`

Cada elemento preparado debe contener, como mínimo:

```json
{
  "event_id": "abc123",
  "title": "Titular",
  "url": "https://...",
  "drafted_source_count": 4,
  "sources_at_draft": ["Fuente A", "Fuente B", "Fuente C", "Fuente D"],
  "prepared_at": "ISO-8601",
  "factual_summary": "Base factual verificada",
  "revision": 1,
  "variants": [
    {"label": "Principal", "text": "Tuit completo", "url": "https://twitter.com/intent/tweet?text=..."},
    {"label": "Remate 1", "text": "Tuit completo", "url": "https://twitter.com/intent/tweet?text=..."},
    {"label": "Remate 2", "text": "Tuit completo", "url": "https://twitter.com/intent/tweet?text=..."},
    {"label": "Remate 3", "text": "Tuit completo", "url": "https://twitter.com/intent/tweet?text=..."}
  ]
}
```

La app cruza `event_id` con `status.json` para mostrar el formato **Redactada con 4 (6)**: 4 fuentes en el momento de redactar y 6 fuentes actuales.

## Acciones web

- **Ya publicada**: retira de la bandeja y registra `published`.
- **Desestimar**: retira de la bandeja y registra `dismissed`.
- **Rehacer**: pide instrucciones, retira la versión actual y devuelve el mismo `event_id` a `PROCESSING` con `selection_mode=REWRITE`.

## Corte a web

No activar hasta desplegar y validar la app:
1. desplegar `/ttittulares/`;
2. validar lectura y escritura;
3. cambiar `ttittulares/control-mode.json` a `web`;
4. actualizar las automatizaciones :15/:45 para escribir `ttittulares/prepared.json`;
5. retirar envío/control Telegram de TTiTTulares;
6. mantener el radar independiente y la verificación editorial.
