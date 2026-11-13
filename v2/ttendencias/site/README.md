# TTActualidad V2 · Web de pruebas

Primera versión visual, completamente separada de V1. Archivos estáticos: `index.html`, `styles.css`, `app.js`.

## Funcionalidad
- Top 30 de España en orden, con estados editoriales reales.
- Listas de explicaciones capturadas, sin equipararlas a publicaciones aprobadas.
- Búsqueda, filtros, fichas de lectura y enlaces HTTPS a fuentes citadas.
- Refresco automático de 90 segundos y aviso de ranking caducado (>45 min).
- Adaptación a móvil y escritorio. Sin credenciales ni acciones editoriales.

## Datos
Solo lectura de `v2/ttendencias/state/web-top30.json` y `listas.json` de la rama `feature/ttactualidad-v2-clean` en GitHub público. No hay API de V1 ni tokens en cliente. La captura Top 30 procede de la fuente configurada en V2; no afirmar verificación directa en X.

## Prueba
Abrir `index.html` mediante un servidor HTTP estático. Por ejemplo, desde este directorio: `python -m http.server 8765` y visitar `http://localhost:8765`. El workflow `ttactualidad-v2-web.yml` valida el código y adjunta un ZIP descargable en GitHub Actions.

## Publicación
**Aún no desplegada en una URL HTTPS pública.** La GitHub Pages actual del repositorio sirve V1 desde main y no debe sobrescribirse. Tampoco se utiliza el proyecto Vercel pausado. Desplegar esta carpeta en un alojamiento estático separado (p. ej., un nuevo proyecto Cloudflare Pages) cuando esté disponible la conexión o credenciales de despliegue. No alterar la configuración de Pages de V1.

## Próxima iteración
Validar navegación real desde móvil, contraste de datos con la cola y diseño de fichas. Solo después valorar imágenes, avisos o funciones editoriales.
