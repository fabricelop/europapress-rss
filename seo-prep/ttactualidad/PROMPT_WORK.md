# ENCARGO PARA PEGAR EN WORK — SEO TTActualidad
**No ejecutar hasta recuperar Work. Este archivo es un guion, no una orden ejecutada.**

Quiero mejorar la indexación en Google y Bing del Site **EXISTENTE**:
https://ttactualidad.rainyraven22.chatgpt.site/

**NO quiero comprar dominio, cambiar de URL, pagar un servicio ni crear una web nueva.** El Site actual ya es público. Conserva todas las funciones y su aspecto: Top 30, buscador, acordeón de tendencias, imágenes, noticias, navegación, historial, fuentes, accesibilidad, versión móvil y vínculos con iPhone y GitHub. No alteres TTiTTulares, TTendencias, editorial, X, Buffer, PC, imágenes, decisiones ni los flujos de publicación.

## Primero: leer y diagnosticar sin modificar
1. Lee desde `main` del repositorio `fabricelop/europapress-rss` el paquete `seo-prep/ttactualidad/README.md`, `VALIDACION_Y_ALTERNATIVAS.md`, `prepare_seo.py` y `test_prepare_seo.py`. Trabaja sobre el código REAL del Site de ChatGPT, no sobre `docs/ttactualidad/index.html` (respaldo histórico distinto).
2. Abre el Site ORIGINAL desde Work. Guarda una versión restaurable. Inspecciona su publicación, HTML inicial, rutas, enlaces, canonical, meta robots, `robots.txt`, `sitemap.xml`, sitemap actual, cabeceras/estado HTTP, renderizado para robots, permisos públicos, la existencia de `noindex` y límites concretos del runtime de Sites. No presumas que una ruta es servible o indexable solo por ponerla en React.
3. Confirma cómo se verificará una propiedad **URL-prefix** en Google Search Console y Bing sin control DNS del subdominio; si Sites no expone método de verificación, documenta el bloqueo y no finjas que la propiedad está verificada.

## Preparación de datos
4. Lee `trends/site-top30-current.json` desde GitHub `main` (no confiar en archivo antiguo); confirma `radar_live_verified`. Selecciona cinco explicaciones **EXPLICADAS**, con `editorial_id`, revisión, fecha real, fuentes y texto. Evita varios nombres que describen el mismo acontecimiento salvo que aporten respuestas materialmente distintas.
5. Reutiliza la explicación **literal** guardada. No inventes detonantes, cifras, declaraciones, posición en X ni fechas de publicación. Un Top 30 orientativo sin verificación de X **no es un ranking oficial ni en tiempo real**.
6. Usa el generador offline `seo-prep/ttactualidad/prepare_seo.py` para preparar un manifiesto y previsualizaciones `noindex`; esas previsualizaciones NO son producto ni URL pública.

## Implementación en Site ORIGINAL (solo si se comprueba viabilidad real)
7. Crea páginas **realmente públicas y distinguibles** por cada episodio, bajo una ruta permanente propuesta `/tendencias/<slug>-<id-editorial>/`. Comprueba que la ruta devuelve HTTP 200 directamente al abrirla en incógnito y que su HTML contiene contenido relevante. **No** utilices rutas con `#` para SEO. Si Sites no soporta rutas indexables, **NO afirmes que las has creado** y pasa al apartado de alternativa.
8. Cada página debe incluir: H1 y `title` únicos por tema, meta description fiel de la explicación original, fecha de explicación, fuentes verificadas citadas en editorial, enlace a Top 30, `lang=es`, canonical apuntando a su URL real, JSON-LD `Article` solo con propiedades comprobadas; `NewsArticle` se reservará para piezas de noticias reales si se trabajan después. No insertar imágenes IA sin asociación/estado público verificado y permiso de exposición.
9. Los enlaces del Top 30 deben ser `<a href="/tendencias/...">` reales y rastreables, sin alterar la interacción existente. Mantén el buscador/plegable y los colores de antigüedad. Las URL no deben depender del puesto 1–30. Una revisión del mismo episodio actualiza esa página y una historia material nueva recibe ID y URL distinta. No publicar automáticamente las explicaciones pendientes o sin fuentes.
10. Previsualiza primero. Revisa tanto los cinco enlaces como todos los flujos previos: noticias, tendencias, fuentes, imágenes, buscador, acordeón, X, Buffer si los hay en el Site y rendimiento móvil. Si una regresión aparece, restaura la versión anterior.
11. Solo después de verificar páginas públicas HTTP 200, crea `sitemap.xml` y `robots.txt` si Sites permite servirlos, con **solo URLs indexables reales**, y `lastmod` editorial real. Comprueba status, Content-Type y que Google/Bing pueden acceder; no subir sitemaps con rutas inventadas. Si Sites gestiona robots/sitemaps automáticamente, intégrate con ese mecanismo, no publiques dos versiones.
12. Evita contenido duplicado, páginas casi vacías, texto inventado y palabras «hoy» que permanezcan sobre hechos antiguos. Una página histórica debe conservar fecha visible y no revalidarse sin nueva comprobación factual.

## Indexación y aceptación
13. Comprueba con la inspección de URL de Google Search Console (tras verificación autorizada) y Bing Webmaster Tools. Si necesitan iniciar sesión o confirmar propiedad, deja preparado el paso y solicita únicamente la acción explícita necesaria. No emplees contraseñas ni tokens en GitHub, logs ni chats.
14. No garantices que Google indexe o posicione en horas. Informa por separado de: URL publicada, rastreable, sitemap entregado, propiedad verificada e indexación efectiva.
15. Entrega resumen final con cinco URLs realmente servidas, captura de la página pública y validación del HTML, sitemap si procede, incidencias, coste adicional 0 €, cambios de versión del Site, rollback probado y resultados reales de Search Console si disponibles.
16. Actualiza la memoria maestra original `/PROYECTOS APP/TTActualidad-Memoria-Completa-2026-10-29.md` preservando el resto.

## Si Sites no admite páginas/SEO efectivo
No arriesgues la app ni crees webs con otra URL sin pedir autorización. Explica qué limita el Site (rutas, HTTP, head SEO, archivos públicos, autenticación de Search Console), qué mejora mínima sí puede hacerse en portada y qué alternativa **gratuita** queda disponible más adelante. No comprar dominios.

**OBJETIVO:** que una búsqueda como «por qué es tendencia Broncano» pueda encontrar una explicación editorial accesible de TTActualidad bajo la dirección existente, cuando el Site lo permita. No alterar el circuito editorial ni inventar éxito de indexación.
