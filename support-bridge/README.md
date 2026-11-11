# TTActualidad · puente de soporte Windows

Rama aislada de `main`, no altera el flujo editorial normal.

- `next.json`: orden de trabajo con ID único y fecha de caducidad. El agente Windows la consulta cada 20 s mediante `gh api`.
- `results/<id>.json`: resultado resumido de cada trabajo, sin stdout/stderr crudos.
- Cada ID se procesa a lo sumo una vez. Los comandos PowerShell arbitrarios exigen confirmación interactiva adicional en Windows; los diagnósticos nativos solo leen datos.
- No abrir puertos ni usar administrador. Todos los resultados de esta rama pueden ser públicos: NUNCA incluir credenciales ni datos personales; el agente solo transmite líneas `TTRESULT:` y estados.
- Para detener el agente se quita el acceso directo del Inicio y se cierra su proceso.

La orden debe tener `version:1`, `id:"ttb-..."`, `expires_at` ISO UTC, y `steps` (1–8) con `kind:"builtin"` y `name:"editorial-queue"|"editorial-runtime"|"editorial-guard"|"listener-summary"` o `kind:"powershell"` con `script` (aprobación local explícita).
