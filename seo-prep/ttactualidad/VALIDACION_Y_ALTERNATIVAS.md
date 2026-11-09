# TTActualidad · SEO: pruebas, límites y alternativa sin dominio

## Estado de la auditoría (09/11/2026)
- El propietario confirmó que `https://ttactualidad.rainyraven22.chatgpt.site/` es pública.
- El acceso automatizado del asistente a portada, `/robots.txt`, `/sitemap.xml` no obtuvo contenido verificable. **No equivale a afirmar 404, bloqueo o noindex**. Repetir en navegador Work y registrar HTTP.
- El repositorio `fabricelop/europapress-rss` contiene el Top 30 de datos; el Site real es un proyecto de ChatGPT Sites separado. No aplicar el respaldo `docs/ttactualidad/index.html` pensando que modifica el sitio público.
- `trends/site-top30-current.json` tiene `status=EXPLICADA`, `editorial_id`, `revision`, `explained_at`, `verification_sources`, `explanation`. En la instantánea examinada, `radar_live_verified=false`; **no proclamar clasificación oficial ni puesto confirmado de X**.
- `site:ttactualidad.rainyraven22.chatgpt.site` no dio hallazgos confirmados en la búsqueda externa consultada. Los filtros de búsqueda `site:` **no son un inventario exhaustivo del índice**. Consultar Search Console para certezas.
- Costo permitido: **0 € adicional**. No comprar `.es`, no añadir hosting de pago, no proponer registro DNS que no controla el propietario.

## Checklist previa a cualquier cambio de Site
- [ ] Abrir Site en incógnito y desde Work: portada 200 y contenido.
- [ ] Guardar versión de restauración; anotar ID/versión original.
- [ ] HTML devuelto antes de JS: H1, explicación útil, href reales; si hay JS, comprobar el HTML renderizado por Google.
- [ ] Consultar cabeceras `X-Robots-Tag`, `meta[name=robots]`, `robots.txt`; no asumir estado.
- [ ] Consultar `sitemap.xml`; si existe, validar contenido y URLs reales.
- [ ] Probar ruta secundaria inexistente: ¿respuesta 404 verdadera o SPA 200 con portada? Una SPA 200 genérica sin el contenido de la ruta no es una página SEO.
- [ ] Comprobar si el runtime Sites permite configurar rutas HTTP, SSR/SSG, título/description/canonical por ruta, robots y sitemap; algunas capacidades podrían no existir.
- [ ] Confirmar que ninguna respuesta requiere cuenta/autenticación para un lector o rastreador.

## Criterios de aceptación de cinco páginas piloto
- [ ] Las cinco páginas corresponden a `EXPLICADA`, ID/revisión/fecha reales y al menos una fuente editorial; evitar explicación duplicada de un solo acontecimiento.
- [ ] La URL HTTP **real** no contiene fragmento `#` ni dependen de `rank`. Solo URLs implementadas se envían a Google.
- [ ] Cada ruta 200 muestra título y explicación diferentes en HTML, incluso sin pulsar un acordeón ni usar login.
- [ ] La portada enlaza con `<a href>` real a cada página; enlaces cruzados no repetidos.
- [ ] Canonical absoluto apunta a la URL real de la página y es coherente con sitemap.
- [ ] H1, title, meta description únicos y fieles. `lang=es`, viewport móvil, fecha editorial visible, fuentes.
- [ ] JSON-LD `Article` solo con propiedades reales; NO usar `NewsArticle` indiscriminadamente en tendencias.
- [ ] Fecha `dateModified` cambia solo con comprobación/edición factual, NO por cambio de puesto o hora de sondeo.
- [ ] Ninguna página `noindex` en producción. Los HTML de `previews/` sí son siempre `noindex` y NO se publican.
- [ ] Ninguna explicación declara «tendencia oficial» cuando `radar_live_verified=false`.
- [ ] Imágenes únicamente si originales públicas, verificadas y asociadas al episodio y revisión exactos.
- [ ] Portada, Top 30, buscador, desplegables, móviles, fuentes, noticias, accesibilidad, datos, imágenes y todos los botones funcionan igual tras la publicación.
- [ ] Sitemap real con solo URL 200, `lastmod` verdadero y ninguna duplicada. Si no se puede servir sitemap, documentarlo sin simularlo.
- [ ] Comprobar Search Console: propiedad verificada, URL inspection, Page indexing (motivos reales), sitemaps. Bing: validación equivalente.
- [ ] Guardar versión, prueba en incógnito y plan de restauración verificable.

## Distinción entre resultados
| Observación | Qué significa | Qué NO significa |
|---|---|---|
| `PREVIEW noindex` en repositorio | Contenido preparado | Página pública |
| URL propuesta en JSON | Contrato de futura ruta | HTTP 200 real |
| HTTP 200 con HTML útil | Página alcanzable | Indexación garantizada |
| Sitemap enviado | URL sugerida al rastreador | URL indexada |
| Search Console «URL está en Google» | URL indexada a esa fecha | Posicionamiento para todas las búsquedas |
| Búsqueda `site:` sin resultados | Indicio no concluyente | Prueba exhaustiva de no indexación |

## Search Console sin dominio propio
1. Abrir https://search.google.com/search-console/ y escoger **prefijo de URL** que coincida exactamente con `https://ttactualidad.rainyraven22.chatgpt.site/`. La verificación de *dominio DNS* requiere el control DNS, que aquí no existe.
2. Comprobar métodos de propiedad aceptados: archivo HTML, etiqueta meta en `<head>`, Analytics o Tag Manager, según los controles disponibles. Escoger solo uno realmente editable con el Site. Si ninguno es compatible, documentar el bloqueo y no fingir verificación.
3. Tras verificar, inspeccionar portada y piloto; solicitar indexación puntualmente, no mandar cientos de URLs. Subir sitemap solo si existe una URL pública válida.
4. Repetir en https://www.bing.com/webmasters/ según opciones de verificación compatibles. No prometer éxito por tener cuenta.
5. Revisar impresiones, consultas y URLs indexadas después de algunos días/semanas. Sin conclusiones precipitadas para las tendencias efímeras.

## Alternativas SI el runtime Sites no admite rutas rastreables
A. **Primero, en el MISMO Site:** mejorar título/description de la portada, párrafo introductorio semántico del Top 30, explicación breve visible en HTML y enlaces a fuentes; siempre conservar el funcionamiento actual. Es inferior a páginas independientes pero no introduce dominio/coste.
B. **Si el Site tampoco permite editar metadatos/robots:** documentar el límite de plataforma, guardar la preparación y no prometer posicionamiento.
C. **Solo con autorización posterior del propietario:** una capa editorial pública gratuita en GitHub Pages o Cloudflare Pages, con otra dirección gratuita. La URL sería distinta y no debe desplegarse ni presentarse como la actual sin autorización. No comprar dominio.

## Recursos oficiales
- [Google: JavaScript SEO](https://developers.google.com/search/docs/crawling-indexing/javascript/javascript-seo-basics)
- [Google: canonicals](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls)
- [Google: datos Article](https://developers.google.com/search/docs/appearance/structured-data/article)
- [OpenAI: crear y gestionar ChatGPT Sites](https://help.openai.com/en/articles/20001339-creating-and-using-chatgpt-sites)
