# TTiTTulares · control web

Esta carpeta es independiente de TTendencias y contiene el estado de la futura app web de TTiTTulares.

## Flujo previsto

- Radar: :10 y :40, cinco minutos antes de la redacción.
- Redacción: :15 y :45.
- Umbral editorial fijo: **mínimo 4 fuentes generales distintas**.
- Las noticias con menos de 4 fuentes permanecen únicamente en el radar y no aparecen en la app.
- Si una noticia no llega a 4 fuentes en 24 horas desde su primera detección, desaparece del proceso.
- Al alcanzar 4 fuentes entra automáticamente en elaboración.
- Antes de redactar se mantiene la verificación editorial actual.
- Una novedad material del mismo asunto se crea como un evento/revisión nueva; no reabre la noticia anterior.
- Telegram se mantiene únicamente durante la transición. El corte final será cambiando `control-mode.json` a `web`.

## Fuentes

La app muestra **fuentes funcionando / fuentes configuradas**, por ejemplo `14/14`.

La comprobación y recuperación de cada fuente se realiza dentro de su propio worker concurrente: origen principal, fallbacks específicos y, si hace falta, fallback adicional. Una fuente fallida no bloquea ni invalida el barrido; el radar continúa con las restantes. No existe una segunda fase bloqueante dedicada a reparar fuentes.

## Vistas de la app

- **Listas**: noticias ya redactadas y pendientes de decisión/publicación.
- **En elaboración**: noticias que ya alcanzaron al menos 4 fuentes y están en la cola editorial.

No hay vista de noticias con 1, 2 o 3 fuentes.

## Bandeja `prepared.json`

Cada elemento preparado contiene `event_id`, titular, URL, número de fuentes al redactarse, fuentes, fecha, base factual, revisión y las variantes de publicación.

La app cruza `event_id` con `status.json` para mostrar **Redactada con 4 (6)**: 4 fuentes al redactarla y 6 fuentes actuales.

## Acciones web

- **Ya publicada**: retira de la bandeja y registra `published`.
- **Desestimar**: retira de la bandeja y registra `dismissed`.
- **Rehacer**: pide instrucciones y devuelve la noticia a `PROCESSING` con `selection_mode=REWRITE`.

## Corte a web

No activar hasta desplegar y validar la app:
1. desplegar `/ttittulares/`;
2. validar lectura y escritura;
3. cambiar `ttittulares/control-mode.json` a `web`;
4. retirar el envío/control Telegram de TTiTTulares;
5. mantener radar y verificación editorial independientes.
