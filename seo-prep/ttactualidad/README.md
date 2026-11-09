# TTActualidad — SEO listo para Work, sin tocar el Site
**Preparación: 9 de noviembre de 2026 · Estado: SOLO PREPARADO, NO DESPLEGADO**

## Restricciones innegociables
- Site público EXISTENTE: https://ttactualidad.rainyraven22.chatgpt.site/
- **0 € de dominio nuevo**, sin compra ni planes de pago adicionales.
- No crear otro Site ni cambiar la URL publicada. No tocar el Site hasta que Work vuelva y el editor ordene aplicarlo.
- No alterar iPhone, Listas, Top 30, TTiTTulares, TTendencias, X, Buffer, automatizaciones, imágenes, cuentas, usuarios, SEO actual o datos editoriales.
- **No reescribir** explicaciones, atribuciones, remates, fuentes, fechas, estado de verificación ni identidades.
- No afirmar que una ruta existe o está indexada sin respuesta HTTP y comprobación de Google Search Console.
- Mantener el carácter editorial informativo e independiente. No presentar radar orientativo como Top 30 oficial de X.

## Qué hay en este paquete
- `prepare_seo.py`: generador **local, offline y NO PUBLICADOR** de fichas SEO piloto a partir de `trends/site-top30-current.json` (fuente de referencia del Top 30). Genera HTML **noindex** de previsualización y un manifiesto con URLs candidatas **NO desplegadas**. No genera sitemap público.
- `test_prepare_seo.py`: tests de fecha, nombre, slug, identidad, revisión, escaping, fuentes, noindex y no-deploy.
- `PROMPT_WORK.md`: encargo listo para pegar cuando Work vuelva.
- `VALIDACION_Y_ALTERNATIVAS.md`: comprobaciones previas, aceptaciones, Search Console/Bing y límites de Sites.
- `.github/workflows/ttactualidad-seo-prep.yml`: test de preparación, sin publicar ni acceder al Site.

## Cómo hacer una prueba offline
Desde la raíz del repositorio:
```bash
python3 -m unittest discover -s seo-prep/ttactualidad -p 'test_*.py' -v
python3 seo-prep/ttactualidad/prepare_seo.py \
  --input trends/site-top30-current.json \
  --out /tmp/ttactualidad-seo-preview \
  --names 'Broncano,Golden Boy,James Gunn,#TEM9N,TikTok'
```
Se crean en `/tmp/ttactualidad-seo-preview`:
- `seo-pilot-DRAFT.json` (identidad, título, resumen original, fecha, fuentes, URL **propuesta**, JSON-LD **candidato**).
- `previews/<id-editorial>.html`: páginas locales que llevan explícitamente `noindex,nofollow`; **no** se sirven en producción.

Las cinco tendencias piloto son sugerencias de la instantánea disponible el 9/11. Work debe recargar la fuente vigente y escoger cinco episodios distintos, con fuentes y explicación vigentes, sin inventar ni actualizar contenido por intuición. Si no están esas cinco, el generador toma otras fichas explicadas con fuentes; el manifiesto es un borrador, no una cola de publicación.

## Estrategia para posicionar
La portada genérica es insuficiente para consultas por tema («por qué es tendencia Broncano»). El objetivo es que el **mismo Site** sirva URLs permanentes y directamente rastreables para páginas por episodio:
`/tendencias/<nombre-legible>-<id-editorial>/`.

El ID editorial evita colisiones entre episodios con el mismo término; una nueva revisión del MISMO episodio actualiza la misma URL. El slug debe conservarse en el registro persistente del Site, incluso si cambia el nombre: no reescribir una URL pública ya enlazada. Un episodio materialmente distinto debe tener otro ID y URL. No utilizar `#/tendencias/...` para páginas de Google.

El cuerpo de cada página debe exponer HTML legible SIN depender de iniciar sesión, pulsar acordeones, esperar interacciones ni ejecutar scripts pesados. Debe incluir título único, descripción, explicación literal, fechas reales, fuentes, enlace de retorno, datos estructurados `Article` cuando los datos sean completos. Un `NewsArticle` solo correspondería en la fase posterior de noticias realmente publicadas y atribuidas.

**No crear sitemap.xml de rutas imaginarias.** Solo después de que las páginas de producción respondan HTTP 200, se vean en incógnito, sean públicas, canónicas y contengan el contenido correcto. El `lastmod` deberá ser una fecha de actualización real, no el momento en que cambió el puesto en el Top 30.

## Comprobaciones realizadas y pendientes
- El usuario confirmó explícitamente que el Site es **público**.
- Intentos de acceso externo automatizado a portada, `/robots.txt` y `/sitemap.xml`: **no accesibles con las herramientas de verificación**, lo que no demuestra un 404 ni un bloqueo. Work ha de comprobarlos en su navegador/red.
- El repo tiene datos de las tendencias en `trends/site-top30-current.json`, pero **no contiene necesariamente el código fuente del Site de ChatGPT**.
- La última instantánea examinada indicaba `radar_live_verified: false`. Las posiciones son orientativas.
- Google Search Console y Bing Webmaster Tools: **sin verificar propiedad y sin enviar sitemaps** (requieren acceso del propietario). No afirmar indexación.
- Las funciones de enrutamiento/HTML personalizado/robots/sitemap de ChatGPT Sites dependen del runtime, y deben comprobarse en Work antes de comprometer cambios. No inventar rutas.
- Se mantiene 0 € de coste adicional; nunca registrar/contratar dominio.

## Documentación externa
- ChatGPT Sites (OpenAI): https://help.openai.com/en/articles/20001339-creating-and-using-chatgpt-sites
- JavaScript SEO y enlaces rastreables (Google): https://developers.google.com/search/docs/crawling-indexing/javascript/javascript-seo-basics
- Duplicados y canónicas (Google): https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls
- Article structured data (Google): https://developers.google.com/search/docs/appearance/structured-data/article
- Google Search Console: https://search.google.com/search-console/
- Bing Webmaster Tools: https://www.bing.com/webmasters/

## Orden de trabajo en Work
1. Abrir exactamente el Site existente en Work, **inspeccionar sin editar** y guardar una versión de recuperación.
2. Validar si Sites soporta rutas públicas distinguibles, HTML servido al rastreador, títulos/metadatos por ruta, enlaces `href`, `robots.txt`, sitemap y JSON-LD. No fingir soporte.
3. Recargar el Top 30 en GitHub `main`; generar cinco fichas piloto; verificar exactitud editorial, duplicados y fuentes.
4. Implantar en el **mismo Site** únicamente si el runtime lo permite sin romper nada. Previsualizar antes de publicar.
5. Publicar una sola vez tras probar portada y rutas en incógnito; probar responsive y flujos intactos.
6. Solo entonces preparar sitemap para URL existentes y asistir al usuario con verificación de Search Console/Bing; registrar pruebas, resultados y rollback.
7. Guardar cambios/decisiones en esta carpeta y actualizar memoria maestra original.
