# Autoridad editorial de Noticias V2

`editorial_state_v2.py` coordina el consumidor local con los archivos individuales
de la rama `feature/ttactualidad-v2-clean`. No abre navegadores ni publica.

## Interfaz

```python
store = EditorialGitHubStore(github_token)
service = EditorialService(store)  # lease 600 s, máximo global de 3 trabajos
plan = service.preview()           # lectura, sin reclamar ni recuperar estados
claim = service.claim(worker_id, private_token)
```

`claim` devuelve `job`, `event`, `commit_sha` y `verified`; `job=None` significa
que no hay capacidad o trabajo elegible. `event.source_context` incorpora el
índice de fuentes para construir el prompt y no se persiste dentro de la noticia.
El token privado debe tener al menos 24 caracteres; GitHub solo recibe su SHA256.

El trabajador usa, en orden:

1. `prepare_send(job_id, worker_id, token, prompt_sha256, command_id, session)`.
   Solo puede enviar cuando obtiene **`send_authorized=True`**. Un resultado
   repetido o una confirmación de commit incierta nunca autoriza otro envío.
2. `submitted(job_id, worker_id, token, conversation_url_sha256=...)` después
   de confirmar el único envío y el turno visible con ID/revisión/comando exactos.
   Sustituye la huella de la página inicial por el SHA256 de la conversación
   confirmada, sin guardar su URL en GitHub.
3. `heartbeat(job_id, worker_id, token)` mientras espera. Renueva el lease y
   vuelve a comprobar revisión, decisiones y propietario.
4. `captured(job_id, worker_id, token, answer_sha256, local_journal_id)` después
   de guardar la respuesta completa en el diario privado local.
5. `complete(job_id, worker_id, token, record)` con el READY validado por
   `editorial_contract_v2.py` y después de cerrar el Chrome que pertenece al job.

`session` contiene identificadores opacos `session_id`, `private_journal_id` y
`conversation_url_sha256`; nunca la URL de conversación. `fail(..., code,
safe_preflight=False)` acepta únicamente un código de error seguro, sin texto de
conversación, credenciales o excepciones arbitrarias.

## Garantías y recuperación

- La selección es FIFO por fecha real de entrada a Pendientes y después job ID.
  Cada claim cuenta las autoridades individuales y usa `expectedHeadOid` en la
  mutación Git: varios PCs o procesos no pueden superar juntos tres puestos.
- Cada acción relee el estado fijado a un commit y comprueba la propiedad del
  lease. Las decisiones terminales, el descarte y una revisión superior impiden
  que un trabajador antiguo envíe o publique un READY.
- Un fallo de arranque antes de `send_intent` permite hasta tres intentos seguros.
  Un lease caducado antes del envío vuelve a Pendientes dentro de ese límite.
  Después de un `send_intent`, nunca se vuelve automáticamente a Pendientes:
  se requiere recuperar el mismo chat o una decisión manual.
- `preview().maintenance_needed` identifica trabajos activos caducados incluso
  si no queda ninguna pendiente. El daemon puede lanzar un consumidor para
  ejecutar el saneamiento mediante CAS; `preview` por sí mismo no escribe.
- Captura y READY son inmutables por hash y bytes. `complete` guarda primero el
  registro, verifica sus bytes y su commit de origen y después cierra
  job/noticia/índices como READY en otro commit atómico. Así `result.commit_sha`
  referencia el commit real del registro sin autorreferencias imposibles.
- Un conflicto recalcula desde el estado actual y conserva cambios de otros
  proyectos. La lectura de vuelta de los archivos escritos es obligatoria.
  Los reintentos de una captura o un READY idénticos no los duplican.
- El índice y la cola mantienen la misma fecha del último radar: un heartbeat
  editorial no hace pasar una captura antigua por datos recién recuperados.
- Solo se escriben noticias, jobs, registros READY y sus dos proyecciones bajo
  `v2/ttittulares/`. Las decisiones se leen; no se crean ni modifican aquí.
  No se escriben imágenes, publicaciones, estados V1 ni TTendencias.

La implementación y sus pruebas no certifican por sí solas instalación o
ejecución real en Windows. Eso exige una primera noticia con respuesta real,
persistencia verificada y cierre comprobado de su navegador propio.
