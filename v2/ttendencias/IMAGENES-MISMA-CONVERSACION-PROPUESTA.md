# TTActualidad V2 — imágenes en la MISMA conversación (propuesta, NO activada)

Fecha: 2026-11-14. Estado: análisis técnico, **sin generación ni publicación activada**.

## Decisión de diseño
Es viable **probar** texto e imagen en el mismo chat ChatGPT V2 (dos turnos dentro del mismo chat), reutilizando contexto, pero la entrega de un archivo binario auténtico y su asociación segura al ID/revisión NO están implementadas en V2. No prometer que el editor web de ChatGPT permite siempre generar, descargar y verificar el original en sesión Chrome automatizada.

## Flujo esperado
1. Seleccionar la tendencia con el mismo ranking T1→T30 y reservar el ID/revisión/episodio con GitHub CAS.
2. Abrir el Chrome aislado V2 y una conversación por tendencia; investigar y capturar **primero el texto** conforme al contrato vigente. Guardar inmediatamente el texto + hash + URL y persistir/verificar la captura GitHub, para que nunca se pierda ni dependa del paso gráfico.
3. Solo si una política editorial permite imagen y el texto está confirmado, **en la misma conversación** enviar una segunda solicitud de imagen, claramente separada del texto. Marcar un trabajo gráfico separado con `trend_id`, `revision`, `episode_token`, `explanation_sha256`, `image_attempt` y `chat_url`.
4. Recuperar el archivo original de la imagen (PNG/JPEG/WebP reales, no un SVG inventado, ni captura de pantalla, ni URL de chat, ni miniatura). Comprobar MIME por contenido, dimensiones, bytes máximos y SHA-256 del archivo. Guardar original de forma persistente y un enlace estático estable accesible por la web.
5. Asociar mediante escritura condicional: exactamente el mismo ID/revisión/episodio/hash del texto; sin regenerar si ya hay imagen verificada o si el envío de imagen está en estado incierto. Registrar el comprobante de asociación y relectura de GitHub; luego cerrar navegador, comprobar cero Chrome V2 y pasar a la siguiente tendencia.
6. Si ChatGPT Images tarda, el DOM cambia, falla la descarga o la imagen no supera validación: preservar texto YA capturado, cerrar de forma segura y dejar estado de imagen `pending/recovery/failed`. **Nunca** bloquear el siguiente texto ni rehacer la explicación por un fallo gráfico.

## Cambios de código necesarios
- `editorial_run_v2.py`: ahora extrae un único par mensaje-respuesta y cierra Chrome **antes** de persistir en GitHub; se requiere separar un checkpoint editorial antes de un segundo mensaje de imagen. Nunca alterar el protocolo probado de un solo envío editorial.
- `chatgpt_transcript.py`: el extractor actual valida un solo par; debe capturar y congelar la respuesta editorial antes de que existan dos turnos. Para la imagen hacen falta localizadores independientes y confirmación de finalización.
- `listas_v2.py` y `web_top30_v2.py`: añadir referencia verificada y estado gráfico sin alterar `captured_review` o `ready`; la imagen no implica revisión ni autorización de publicar.
- Reutilizar los controles contrastados de V1: `trends/apply_ai_image_outbox.py`, origen `chat-imagegen`, validación de bytes y asociación por ID/revisión/hash; adaptar a cola V2 totalmente aislada, sin escribir en V1.
- Crear tests de reintentos, cierre de Chrome, fuga de imágenes entre revisiones, imagen recibida tras abandono del Top30, causas no confirmadas, colas sin elementos y ausencia de publicación accidental.

## Límites y criterios de aceptación
- El paso de imágenes será **opt-in** y permanecerá desactivado hasta demostrarlo con una tendencia no sensible en una prueba de extremo a extremo.
- Una sola imagen por tendencia/revisión y cero publicaciones en X, Buffer, Instagram o Telegram.
- Proteger editorialmente los temas con fallecimientos, víctimas o violencia; usar representación periodística respetuosa o no generar si la política lo exige.
- Limitar tiempos y concurrencia: si la imagen consume la misma sesión del consumidor, retrasa las 30 explicaciones. Evaluar latencia real antes de habilitar en masa. Prioridad absoluta para texto y Top30.
- Verificación final: texto persistido, imagen descargada de verdad, comprobación MIME/SHA, URL estable HTTPS, referencia visible en V2 y Chrome V2 cerrado; **no confundir una imagen en el chat con un fichero asociado en la aplicación**.

## Estado
Diseño documentado. No se ha implementado ni activado el segundo turno de imagen ni se han modificado V1/producción. La primera fase pendiente es una prueba de extremo a extremo con 1 tendencia, sin publicaciones.
