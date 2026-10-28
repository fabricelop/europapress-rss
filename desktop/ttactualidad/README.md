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
