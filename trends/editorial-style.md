# TTendencias — línea editorial de imágenes

## Referencia positiva

La referencia aprobada es la imagen de **Cleveland**: una **escena narrativa única** de caricatura/viñeta editorial, visualmente rica, con protagonista integrado en un entorno reconocible, acción, expresiones, profundidad, iluminación, textura y una metáfora o exageración visual que cuenta el chiste por sí sola.

El criterio decisivo es: **si se elimina todo el texto de la imagen, el gag y la relación con el detonante real deben seguir entendiéndose**.

## Regla de marca: guindilla solo en el texto (16/10/2026)

El emoji `🌶️` distingue el remate escrito, **nunca es un elemento del gag gráfico**. Rechazar toda imagen que contenga guindillas, chiles, pimientos picantes, iconos, logos, siluetas, mascotas, sellos o decoración que represente ese símbolo, en cualquier zona del lienzo. No trasladar el marcador `🌶️` desde el texto a la imagen. El gag debe surgir del significado del remate y del hecho verificado. La ausencia de guindilla se comprueba visualmente tras la generación, sin alterar `closer_text`.

## Composición obligatoria

- Una escena coherente, no un esquema.
- Protagonista(s) + causa real de la tendencia + exageración/metáfora visual + remate escénico.
- Acabado de viñeta editorial profesional, ligeramente caricaturesco, rico en detalle.
- Fondo y entorno con función narrativa; evitar sujetos flotando sobre fondos abstractos.
- Cero texto siempre que sea posible. Si hace falta, que sea breve y diegético: un cartel, rótulo u objeto dentro de la escena.
- En asuntos graves o con víctimas, usar una ilustración editorial seria o dirigir la sátira a responsables/gestión; nunca a víctimas o sufrimiento.

## Anti-modelo: rechazo obligatorio

No aceptar como final ninguna imagen con estética de:

- infografía, diagrama o esquema;
- flechas, conectores, nodos, cajas o líneas que expliquen relaciones;
- círculos/medallones con caras o avatares;
- marcador, podio o tablero abstracto como composición principal;
- interfaz de televisión, panel de tertulia o dashboard;
- cabezas flotantes, retratos enfrentados o comparación por paneles;
- póster informativo con titulares;
- iconografía plana, clip-art, mascota simple o formas geométricas;
- retrato decorativo sin gag visual;
- composición cuyo chiste dependa de leer etiquetas.

La imagen del ejemplo rechazado de #ChiringuitoLamine —caras dentro de círculos, flechas, medallón central y etiquetas explicativas— representa precisamente el tipo de composición que NO debe volver a aprobarse.

## Control posterior a la generación

La imagen se revisa **después de generarla**, no basta con que el prompt pida el estilo correcto. Si aparece cualquiera de los patrones prohibidos, se descarta y se regenera.

Un item solo puede quedar `ready` si su `image` incluye:

- `style_version: "editorial-scene-v2-cleveland"`
- `style_check.reviewed_after_generation: true`
- `style_check.single_narrative_scene: true`
- `style_check.visual_gag_without_text: true`
- `style_check.no_infographic_layout: true`
- `style_check.no_diagram_arrows_or_connectors: true`
- `style_check.no_ui_or_scoreboard_layout: true`
- `style_check.low_text: true`
- `style_check.depth_lighting_texture: true`

Si no puede superar el control, debe quedar pendiente (`pending_renderer`), nunca publicarse con una imagen de compromiso.
