# TTActualidad V2 — Primer hito funcional (13/11/2026)

## Objetivo único de esta fase

Ver desde PC o móvil el **Top 30 de España**, actualizado automáticamente cada
15 minutos incluso si el ordenador está apagado, con un estado fiable por
tendencia y **la explicación obtenida en su conversación individual de ChatGPT**.

No incluir todavía imágenes, publicación, Instagram, X, Telegram, valoración,
botones de decisión editorial ni nuevas funcionalidades accesorias.

## Flujo exacto

1. GitHub Actions (patrón probado de V1) obtiene GetDayTrends España en los
   minutos 00/15/30/45 UTC, preserva el histórico de entradas/salidas y las
   identidades estables de V2. Fuente única aceptada provisionalmente; no afirmar
   que se observó X directamente.
2. Cada nueva tendencia no explicada entra en cola `pending`; la web muestra
   **Pendiente**. Orden de selección **puesto 1 → 30**, omitiendo las que ya
   tienen explicación vigente.
3. El consumidor V2 reclama el trabajo exclusivamente mediante GitHub CAS,
   cambia a `in_progress` y la web muestra **En elaboración**. Solo debe
   existir un Chrome/ChatGPT de V2 por tendencia, sin usar el perfil V1.
4. Abre **una conversación nueva por tendencia**, investiga, redacta una
   explicación prudente (o declara causa no confirmada), captura, cierra
   todos los procesos del navegador V2 y persiste respuesta + identificador
   + revisión + enlace al chat con verificación de lectura en GitHub.
5. La web muestra **Explicada** junto con el texto; `captured_review`
   significa explicación disponible **pendiente de validación editorial**,
   no READY ni publicada. Si falla la captura después del envío, mostrar
   **Incidencia** y recuperar el chat sin enviar otra vez.
6. Si una tendencia sale del Top 30, **no cancelar** un trabajo ya asignado:
   debe concluir y quedar en el histórico para el caso de que regrese.
   Al entrar de nuevo antes de 24 horas, conservar episodio; si han pasado
   más de 24 horas, aplicar la política de revisión vigente.
7. La web refleja ranking, posición, estado, explicación, frescura del dato y
   momento de captura. Debe funcionar en PC y móvil sin instalar software.
   El estado mostrado se deriva de GitHub V2 (autoridad única). La vista
   pública solo contiene campos necesarios; no revelar tokens/leases.
8. El refresco del Top 30 no depende del ordenador. La **elaboración con
   Chrome V2 local sí depende del PC encendido**, hasta adoptar otro ejecutor
   igual de fiable. No confundir las dos autonomías.
9. Antes de añadir piezas, revisar la solución correspondiente de V1 y
   **reutilizar el patrón probado** cuando sea adecuado. V2 mantiene
   colas, sesiones, despliegues y estado separados.

## Estados visibles

| Estado técnico | Estado web | Significado |
| --- | --- | --- |
| `pending`, `review_pending` | Pendiente | Aún no se ha iniciado |
| `in_progress` | En elaboración | Consumidor ha reservado este ID |
| `captured_review` | Explicada · por revisar | Texto capturado, no validado |
| `ready`, `published` | Explicada | Texto vigente; no significa que V2 publique |
| `capture_recovery`, `cancelled` | Incidencia | Requiere atención, sin reenvío ciego |
| `dismissed` | Desestimada | Sin nueva elaboración |

## Criterios de aceptación del primer hito

- Dos capturas programadas consecutivas con Top 30 completo y fechas distintas,
  realizadas por GitHub con el PC apagado.
- Acceso real por **HTTPS** al mismo panel desde PC y móvil y 30 puestos en
  orden, con captura reciente y aviso claro si caduca.
- Una tendencia sin explicación pasa por **Pendiente → En elaboración →
  Explicada**, reflejado en la web sin recarga manual.
- Cada trabajo usa un **chat distinto** y su Chrome desaparece por completo;
  GitHub conserva texto, ID, revisión y URL del chat.
- Una tendencia que sale mientras está seleccionada se termina sin duplicar.
- Una causa no confirmada genera ficha prudente y visible, no bloqueo.
- Ninguna acción modifica la cola de V1, publica contenidos ni toca servicios
  de producción. El primer hito no se declara terminado hasta probar su
  flujo completo, incluida la URL HTTPS.

## Estado de implementación

- Captura Top 30, historial, cola, editorial individual, captura, GitHub,
  Listas V2 y selección por posición: **implementados y parcialmente
  probados**.
- Cron remoto de 15 minutos: **configurado**, falta comprobar dos ejecuciones
  de horario consecutivas.
- Web V2: **pendiente de completar y desplegar**.
- Ejecución editorial automática que recorra el Top30: **consumidor V2 e instalador Windows implementados**; falta instalarlo y verificar el primer lote autónomo en el PC.
- Publicación V2: **desactivada expresamente**.

## Automatización editorial local (implementación inicial)

- `editorial_daemon_v2.py`: consumidor que consulta la cola y el historial GitHub V2 aproximadamente cada **90 segundos** mientras haya sesión Windows. Prioriza siempre el **Top 30 vigente (puesto 1→30)**, espera si la captura ha caducado, omite las explicadas y no procesa el backlog histórico fuera de ranking.
- Reutiliza `editorial_run_v2.run_one` (ya probado en las tandas manuales): un único navegador exclusivo y nuevo chat por tendencia, persistencia SHA, Listas y web. El siguiente trabajo empieza tras la verificación del anterior. **No hay publicación.**
- `auto_editorial_policy_v2.py` impide reenviar automáticamente un ID/revisión que ya tiene diario local. La cola GitHub verifica también `send_intent` y `lease`. Si cae la red, la sesión o la captura, el trabajo dudoso queda sin reenvío y el consumidor puede seguir con otros elegibles.
- `process_lock_v2.py`: lock de sistema operativo compartido con `editorial_batch_v2.py`; si Windows cierra el proceso bruscamente, el lock se libera, sin interpretar un archivo residual como otra instancia activa.
- `Install-V2-Editorial-Auto.ps1`: descarga todos los módulos desde **un único commit SHA V2**, ejecuta pruebas puras y comprueba Playwright y el perfil Chrome V2. Registra la tarea **`TTActualidadV2-Editorial-Auto`** al iniciar sesión Windows y la arranca en la sesión actual. NO modifica tareas de V1. Guarda logs bajo `%LOCALAPPDATA%/TTActualidadV2/editorial-auto-logs` y estado en `daemon-status.json`.
- `Disable-V2-Editorial-Auto.ps1`: impide nuevos envíos y deshabilita el próximo arranque de la tarea. El chat que esté activo puede terminar su ciclo y cerrarse con seguridad.
- **Puesta en marcha pendiente:** hasta ejecutar el instalador en Windows, el consumidor NO está activado. No confundir código listo con automatización instalada.
- La captura Top30 por cron GitHub funciona sin PC. El consumo editorial con Chrome **sí necesita Windows encendido y sesión interactiva**. Queda disponible reanudación al inicio de sesión. La captura del ranking, la web y las explicaciones comparten siempre el estado de la rama V2.
- El consumidor no renueva ni vuelve a enviar automáticamente una sesión dudosa, aunque su lease haya vencido; la web la identifica como incidencia. La recuperación del chat existente se tratará después de validar el primer lote automático.

### Validación de seguridad
`python -m unittest test_auto_editorial_v2.py` desde el directorio V2 comprueba la selección por ranking, parada por captura caducada, bloqueo de reenvío, exclusión entre procesos y continuidad del plan seleccionado si el término sale del Top30. GitHub CI ejecuta estas pruebas sin navegador ni cambios de producción.
