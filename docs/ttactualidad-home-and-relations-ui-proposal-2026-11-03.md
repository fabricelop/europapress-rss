# TTActualidad · simplificación de APP y web (03/11/2026)

## Estado, autoridad y alcance
- Fuente iOS: build64 en `feature/ttactualidad-relations-build64`, no el main iOS obsoleto.
- La web pública actual es ChatGPT Site `ttactualidad.rainyraven22.chatgpt.site`; **esta propuesta de Site no está desplegada** desde este PR.
- No alterar orden Top30, contenido editorial, aprobación IA, fotos, X/Instagram, Telegram, retirada de Listas, Live Activity, exclusión GoatCounter/Umami ni autenticación del editor.
- Relacionar fichas no debe publicar, fusionar noticias ni generar imágenes.

## APP · build65
1. Cabecera TTActualidad compacta, con línea única/escalado mínimo para iPhone estrecho.
2. Pestaña inicial «Confirmadas» (incluidas automáticas); «Por revisar» exclusivamente para dudas, «Bloqueadas» para decisiones editoriales. Búsqueda manual plegada y opcional.
3. Ante respuesta GitHub parcial, leer **recibos exactos** de acciones por request_id + proyecto + ID + revisión + decisión. Un 5xx/timeout, falta de fichero o recibo de otra revisión no acredita éxito. Aceptación `applied` solo confirma recepción/aplicación de la orden, no fin de redacción; `failed/rejected` cierra como rechazada. Mantener auditoría.
4. Mantener flujo editorial completo build64, imágenes, archivos, publicación, retirada masiva, fichas históricas, login y Live Activity.
5. Compilar IPA/TestFlight solo tras CI nativo. No afirmar que el iPhone ya ejecuta build65.

## Relaciones automáticas: contrato de servidor a revisar
- El matcher del Site60 ya confirma relaciones de alta confianza; ampliar únicamente cuando haya un mismo episodio demostrable por actor/es, acontecimiento específico, dos hechos distintivos, fecha y fuentes. La similitud de titulares por sí sola no basta.
- Persistencia autoritativa: una decisión manual `link` o `unlink` con recibo válido debe sobrevivir a refrescos y sincronización. **No reasociar automáticamente la pareja bloqueada del mismo episodio.** Si cambia el episodio, revalidar; no arrastrar una asociación a otro caso.
- En el snapshot resolver duplicados por pareja de identidades editoriales y episodio; mostrar como `linked` los vínculos automáticos claros, sugerir solamente los ambiguos. Distinguir sugerencia de hecho confirmado y no acusar/atribuir causas desconocidas.
- Prueba de regresión del bug reportado: enlazar noticia+tendencia → cerrar APP → abrir en otro dispositivo → actualizar ambas → comprobar mismo vínculo, sin solicitar segunda pulsación. Repetir con cambio de revisión sin cambio de episodio y con cambio real de episodio.

## Web · una portada de **una pantalla** (propuesta pendiente de implementar)
- Encabezado pequeño: **TTActualidad** + fecha/hora auténtica del último ranking; no inferir «en directo» cuando el dato está viejo.
- Hero: «Lo que mueve la actualidad» + **un asunto principal**, texto factual de una línea y máximo dos chips de tendencias, seleccionados por actividad y certeza editorial, sin forzar noticia cuando no existe.
- Dos accesos protagonistas de dedo grande: **Tendencias · Top30** y **Noticias · actualidad**. Contadores solo con datos válidos; fallback neutro si no hay captura fresca.
- Pie opcional: un movimiento reciente verificable; sin feed, imágenes duplicadas, filtros, hemeroteca ni diez fichas en Inicio. El Top30 y todo el catálogo siguen completos en sus páginas respectivas.
- Tipografía base móvil ≥16px, títulos 20–28px, contraste alto, targets de toque ≥44px y contenedor adaptable a 320px. Una sola pantalla en smartphone normal, scroll mínimo en tamaños muy pequeños.

### Relaciones plegadas en fichas
Patrón de ejemplo debajo de una tendencia:
`Noticias relacionadas (3) ›` (plegado por defecto).
Al pulsar: tres filas **título corto + enlace estable** y opción «Ver todas». En noticia: `Tendencias relacionadas (2) ›`. El bloque siempre indica tipo de relación; no dibujar árbol/hilo expandido de entrada en pantallas pequeñas. Usar `button` con `aria-expanded` y `aria-controls`, texto siempre accesible por teclado y lector. Mantener Hilo para tendencias y Árbol para noticias como modos de detalle cuando el usuario despliega. Sin cambios en puestos Top30 ni en relaciones manuales.

### Apertura rápida de menú
1. Medir en móvil real el tiempo de navegación Inicio→Tendencias y →Noticias (p50/p95 y Web Vitals); no atribuir una lentitud a la red sin trazas.
2. Renderizar encabezado y primer bloque inmediatamente con snapshot válido en caché y etiqueta de frescura; actualizar en segundo plano.
3. Evitar descargar y analizar las 1.000 noticias completas al hacer cada clic: cálculo de relaciones y ranking en ingestion/cron, índices compactos por IDs, TTL explícito y invalidación por revisión.
4. Prefetch solo al foco/touch/hover de menú; lazy-load resto de fichas, fotos `loading=lazy`, paginar. No retrasar navegación por aprobaciones IA ni depender de las imágenes para publicar texto.
5. Pruebas de regresión: rutas directas `/tendencias` y `/noticias`, 320/375/390px, accesibilidad, datos caducados, exclusión analítica, fuentes y sin contaminación de identidad entre episodios.

## Pendientes y limitaciones
La conexión disponible aquí permite editar GitHub y la Biblioteca, pero no ejecutar cambios en el proyecto privado del ChatGPT Site ni inspeccionar el iPhone real. Por eso **no** declarar corregidos en producción el problema de sincronización de relaciones, el menú lento ni la portada web hasta desplegar el Site y medirlo. No se ha tocado ningún original IA, dato editorial, orden remota ni decisión de aprobación.

## Ajuste solicitado por el editor · una sola noticia, varias casillas (03/11/2026)
- En la APP, **no repetir una noticia por cada propuesta**: una fila/cabecera por noticia y episodio, seguida de **todas** las tendencias sugeridas con casillas independientes.
- Debajo, un desplegable «Añadir otras tendencias · Top 30» muestra las 30 tendencias actuales (puesto real). Permite marcar las que tienen identidad de episodio emitida por el Site; no inventa identidad para tendencias no incluidas en el snapshot privado.
- Un único botón «Guardar: N vincular · M descartar» procesa por noticia: cada sugerencia marcada se vincula, cada sugerencia sin marcar se descarta para el mismo episodio, y las otras tendencias del Top 30 no se bloquean. Revalida cada pareja ante el servidor con recibo y commandId estable tras timeout o cierre de APP; la pantalla distingue confirmadas e inciertas. El botón permite descartar todas las propuestas aunque no se haya marcado ninguna.
- La búsqueda manual por parejas se sustituye por «Elegir otra noticia», que muestra esa noticia una sola vez con el mismo Top 30. Las relaciones existentes no desaparecen y los vínculos bloqueados requieren acción explícita distinta.
- Implementación candidata en PR302 / build65. **Sin instalación en iPhone ni pruebas físicas del Site** hasta ver CI.

### Complemento QA build65 (03/11/2026)
- La respuesta de relaciones se canonicaliza en pantalla por pareja `news.id/revision/fingerprint + trend.id/revision/fingerprint`. Una sugerencia antigua no debe duplicar una relación confirmada. Ante estados contradictorios, priorizar la decisión manual y el bloqueo; no escribir cambios silenciosos al backend. Pruebas nativas cubren sugerencia duplicada, bloqueo manual y episodios diferenciados.
- En fichas con sugerencias ambiguas, la casilla vacía significa «Descartar en este episodio» **solo después de pulsar Guardar**. Durante la navegación no se envían decisiones. El selector Top 30 muestra las 30 entradas, pero únicamente son seleccionables aquellas cuya identidad privada exacta está disponible en el snapshot; otras aparecen como «pendiente de identidad editorial» y requieren completar el catálogo seguro en Site. Nunca fabricar fingerprint a partir del título o puesto.
- La cabecera conserva objetivos táctiles de 44 puntos para imágenes, GitHub y refrescar; el título reduce tipografía y escala en una sola línea en vez de comprimir botones.
- Estado de integración: iOS build65 sigue en PR302 draft. Un workflow de Actions en cola no acredita IPA compilada. Aprobación privada y flujo editorial no se sustituyen ni se despliegan por este PR.

## Incidencia «Órdenes por confirmar» · revisión 03/11/2026 (build66)
- En `main`, `pilot/ttactualidad-action-receipts.json` conserva solo las últimas **2.000** respuestas: 1.946 `applied`, 5 `already_applied`, 49 `rejected` en la comprobación. No hay ningún estado `pending` en ese registro. **No equivale a que el iPhone tenga cero pendientes**, ya que su historial reside en `UserDefaults`.
- Colas editoriales observadas: 3 noticias `PROCESSING` y 1 tendencia `preparing`. Son trabajos en marcha, no órdenes por confirmar. No borrar, reenviar, ni completar artificialmente esos estados.
- Build66/0.4.55 añade el botón **«Conciliar órdenes con GitHub»**: lectura selectiva de recibos, decisiones, colas y READY, sin `repository_dispatch`, cambio de fichas ni nueva publicación. Se usa la identidad exacta por `request_id/proyecto/id/revisión/decisión`; los rechazos se cierran como rechazos.
- Para recibos antiguos que ya no están entre los 2.000, se permite retirar el aviso local únicamente si el historial autoritativo documenta un **cierre posterior** de la misma ficha y revisión; no equivale a afirmar que la solicitud original funcionó.
- Las solicitudes sin recibo pueden pasar a **Caducada**, no «Confirmada», solo tras una lectura fresca y completa de los ficheros requeridos, y si no hay trabajo activo para ese elemento; preservar trazabilidad e impedir reenvíos automáticos.
- La comprobación parcial no bloquea la conciliación de aquellos recibos o cierres que sí llegaron. La APP instalada no puede modificarse ni desbloquearse remotamente desde GitHub: requiere instalar build66 y pulsar Conciliar; hasta entonces el contador local puede seguir sin actualizarse.
- Implementación en PR302 (rama iOS basada en build64, sin mezclar el antiguo `main`); necesita CI y prueba física antes de afirmar operatividad. Conservar toda la aprobación privada de imágenes y flujos de Listas, X, Telegram, Instagram y Live Activity.

## Incidencia reiterada: muchos avisos «Esperando GitHub» tras build66 (04/11/2026)
- El editor notificó que el contador seguía elevado después de la corrección. **No afirmar que el contador real del iPhone está despejado** sin recibir el diagnóstico de ese dispositivo.
- En la lectura actual de `main`, el registro de recibos `pilot/ttactualidad-action-receipts.json` contiene 2.000 entradas de respuesta terminal, desde el 20 de octubre al 3 de noviembre. Es una **ventana móvil**, no el universo completo de acciones. `trends/requests.json` es demasiado grande para devolver contenido mediante el conector Contents habitual y su dependencia puede bloquear conciliaciones.
- Build67/0.4.56 cambia la conciliación manual para leer solo **seis** documentos ligeros: recibos, `ttittulares/prepared.json`, cola noticias, decisiones noticias, cola tendencias y decisiones tendencias; no exige `trends/requests.json`. Nunca lanza `repository_dispatch`.
- Cierra únicamente con comprobante exacto, decisión final de misma ficha posterior a la petición, o tras revisión de colas/decisiones actuales. Una solicitud sin comprobante con más de seis horas y sin trabajo activo queda **«Caducada»**, explícitamente **sin verificar ejecución**; una fila sin identidad recuperable requiere al menos 24 horas y queda «No verificable». No se afirma éxito, no se borra auditoría y no se altera contenido del servidor.
- Para peticiones antiguas sin UUID, un recibo posterior equivalente con misma identidad/proyecto/revisión/decisión retira solo la alerta (no atribuye éxito al comando original).
- La APP muestra recuentos de resultados y fuentes inaccesibles, permite desplegar todas las pendientes en vez de solo quince, y ofrece «Copiar diagnóstico» (ID/revisión/acción/estado, sin token) para identificar los avisos aún sin resolver.
- CI de compilación está revalidándose en PR302 (rama iOS derivada de build64), con pruebas de fuentes frescas, cola activa, no reenvío y estados antiguos. **Sin instalación física ni cambio del contador confirmado** hasta instalar build67 y ejecutar conciliación en el iPhone.
- El workflow separa ejecución push y PR en `concurrency.group`, porque antes se cancelaban mutuamente y dejaban la comprobación CI sin jobs.
