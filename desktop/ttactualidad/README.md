# TTActualidad Windows — rediseño moderno

Aplicación de escritorio nativa para Windows con interfaz Qt, conectada a GitHub directamente. El código de la versión antigua Tkinter queda como capa de lectura, normalización y compatibilidad. **El iPhone permanece intacto**.

## Qué cambia

- Nueva barra lateral con 9 secciones; tarjetas editoriales para noticias y tendencias; panel de lectura sin URLs kilométricas; resumen de Listas, elaboración y publicaciones de las últimas 24 h.
- Botones habilitados solo según estado: Desestimar en elaboración, Quitar de Listas/Marcar publicada en Listas; publicación en X solo abre el borrador.
- Foto de archivo contextual cuando la fuente proporciona una URL HTTPS de imagen válida.
- Autenticación independiente de iPhone: botón Conectar GitHub y token personal de alcance limitado al repositorio. Los tokens se guardan en Windows Credential Manager. No se guardan claves en archivos ni en GitHub.
- Sin Cloudflare Worker, ni web externa de TTActualidad, ni navegador integrado; GitHub sigue siendo la autoridad editorial.

## Descargas

- **TTActualidad-Windows-Portable-EXE:** ejecutable portable con interfaz moderna. No dispone de firma de código; la empresa puede bloquearlo.
- **TTActualidad-Windows-Sin-EXE:** ZIP de código fuente con la aplicación .pyw. Requiere Python 3.12 y las dependencias de requirements.txt; sigue sujeto a las políticas corporativas. Consulta GUIA-WINDOWS-SIN-EXE.md.

## Conexión GitHub desde Windows

Pulsa Conectar GitHub y crea un fine-grained personal access token desde GitHub. Selecciona **solo** fabricelop/europapress-rss y permiso Contents: Read and write. Introduce el token una sola vez en la app. La lectura funciona sin token; las acciones se autentican y su aceptación HTTP 204 no equivale a publicación real. El estado se verifica mediante nueva lectura de los JSON autoritativos.

## Seguridad e infraestructura

- La app no modifica URGENTE, ChatGPT Images ni los Workers de otros proyectos.
- No retirar el Worker anterior ni la web antigua hasta verificar completamente la nueva versión en el ordenador.
- Las consultas JSON se ejecutan fuera del hilo de UI; un fallo de red no sustituye el estado anterior por listas vacías.
- La versión Windows es una alternativa al iPhone y puede seguir evolucionando sin cambiar su funcionamiento.


## Vista de escritorio renovada

La distribución responde al espacio de pantalla: el lector ocupa el panel derecho y
la fotografía de archivo aparece como miniatura lateral, nunca encima de los
botones. Las acciones principales permanecen visibles; las secundarias figuran
en **Más ···**. Se puede cambiar el tamaño de los paneles arrastrando su división.

Para cerrar después de X utiliza **Cerrar · Sí / No**. El diálogo diferencia:

- **Cancelar:** no envía ninguna orden, deja la tarjeta intacta.
- **Sí · publicada:** aplica la decisión `published`. Si GitHub confirma, retira
  la tarjeta y añade exactamente una publicación al contador móvil de 24 h.
- **No · retirar:** aplica `deleted`, retira la tarjeta si GitHub confirma y
  no aumenta el contador.

**Publicar en X ↗** abre el borrador en el navegador y presenta después estas
tres opciones; abrir la página NO demuestra que X haya publicado nada.

Las decisiones se contrastan por `request_id` con el comprobante oficial de
`pilot/ttactualidad-action-receipts.json`. Un HTTP 204 por sí solo solo significa
que GitHub aceptó el evento para procesarlo. Un estado pendiente o un error no
puede anunciarse como publicado. La cuenta de 24 h sale de
`pilot/ttactualidad-publication-events.json`, no de estimaciones locales.

Las Listas y Top 30 leen los mismos JSON y aplican las mismas reglas de cierre
que el iPhone. **ChatGPT Images ↗** abre la interfaz real de Images en el navegador,
no genera imágenes desde el proceso Windows. La foto de archivo se resuelve de
GitHub y no se confunde con imágenes IA.


## Contadores desglosados y cierre inmediato en Windows

La cabecera muestra ahora cinco métricas: Noticias en Listas, Tendencias en Listas,
En elaboración, **Noticias publicadas · 24 h** y **Tendencias publicadas · 24 h**.
Los dos contadores de publicaciones se calculan por separado a partir de los
eventos confirmados por GitHub en las últimas 24 horas (ventana móvil).

Cuando se pulsa **Sí · publicada** o **No · retirar**, Windows aparta la tarjeta
**inmediatamente** de la bandeja, sin bloquear la navegación o el cierre de
otras tarjetas. Es un cambio visual provisional: el JSON autoritativo no se
modifica desde la aplicación de escritorio. El contador de publicadas solo suma
un caso cuando GitHub lo confirma; durante la comprobación, la tarjeta de
estadísticas indica `+1 pendiente` (o varias pendientes), para no confundir
una orden aceptada con una publicación efectuada.

La aplicación consulta los recibos por `request_id`. Si el envío falla, el
servidor rechaza la acción o no existe recibo después del tiempo de verificación,
la ficha se **restaura visualmente** y se muestra el motivo. Si el servidor confirma,
la tarjeta sigue oculta hasta que el nuevo estado editoral esté disponible.
**Cancelar** nunca envía una orden ni oculta la tarjeta.

Los cambios son exclusivos de Windows. No se modifican la app iPhone, los
Workers, URGENTE, ChatGPT Images ni las automatizaciones editoriales.
