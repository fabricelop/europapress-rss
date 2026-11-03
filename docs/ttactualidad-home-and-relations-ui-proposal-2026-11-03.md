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
