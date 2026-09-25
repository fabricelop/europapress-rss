# Configuración del trigger Work · TTiTTulares

Repositorio: `fabricelop/europapress-rss`
PR permanente: **#2 · TTiTTulares · canal permanente Ejecutar ahora**

## Trigger
Actividad de Pull Request → nuevo comentario en PR.

## Condición
Ejecutar únicamente cuando:
- repository = `fabricelop/europapress-rss`
- PR = `#2`
- el cuerpo del comentario empiece exactamente por `RUN TTITTULARES`

Ignorar `RUNSTATUS`, `TTITTULARES WORK TRIGGER READY` y cualquier otro comentario.

## Prompt de la tarea
Lee desde `main` `ttittulares/work-manual-run-prompt.md` y ejecútalo íntegramente para el comentario que activó esta tarea. Usa el mismo PR que originó el evento para la telemetría RUNSTATUS.

## Activación segura
La web y el endpoint permanecen bloqueados hasta que exista en el PR #2 un comentario cuyo contenido exacto sea:

`TTITTULARES WORK TRIGGER READY`

Ese comentario solo debe añadirse después de crear y revisar la tarea Work.
