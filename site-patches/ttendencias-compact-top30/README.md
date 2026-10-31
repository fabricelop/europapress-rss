# TTendencias — implementación del Top 30 compacto para el Site original

Proyecto exclusivo: appgprj_6ae4dcf7d7488191a574e5b649e67370
URL pública que debe conservarse: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/

**Estado:** componente React y lógica de filtrado preparados. Aún NO instalados en el Site ni publicados. No crear otro Site. No incorporar «Eliminar imagen IA» ni borrar imágenes o asociaciones.

## Archivos

- CompactTop30.jsx — componente listo para adaptar a la fuente real del Site.
- compact-top30.css — estilos aislados, responsive, buscador de 38px y máximo 320px en escritorio.
- model.mjs — helpers puros para búsqueda, hora Madrid, identidad única y foto IA verificada.
- model.test.mjs — cinco pruebas con Node, sin dependencias.

## Aplicación en el editor de ESTE Site

1. Abrir el proyecto original en ChatGPT Sites y editar su código fuente, no una copia. No sobrescribir a ciegas el contenido proyectado en Biblioteca.
2. Reemplazar SOLO el componente del Top30 existente por CompactTop30 y adaptar la fila de datos a los props indicados abajo. Eliminar el antiguo buscador del árbol visual para evitar duplicados.
3. Seguir usando el componente REAL que ya dibuja la explicación y sus acciones desde renderDetails; no reconstruir ni modificar los datos editoriales.
4. Conservar la carga/actualización de datos y los filtros actuales; pasar los controles existentes por filterControls y aviso de frescura por statusContent. Si el buscador ya es controlado por el estado de la página, pasar query y onQueryChange.
5. Verificar la vista móvil, el top de 30 filas, búsqueda, agrupaciones, miniindicador de IA verificada, y que SOLO una ficha se despliega.
6. Publicar sobre el mismo project_id y verificar la misma URL. No darlo por terminado si el editor no permite guardar/publicar.

Ejemplo orientativo de interfaz de adaptación (nombres de campos internos NO verificados; reemplazar por los reales del código del Site):

    <CompactTop30
      cards={existingTop30.map(row => ({
        cardId: row.stableUniqueCardId, // único por FILA, también si hay contexto agrupado
        rank: row.rank,
        name: row.name,
        explainedAt: row.currentEditorial?.explained_at ?? null,
        groupLabel: row.groupName ?? '',
        searchTerms: row.relatedTerms ?? [],
        imageVerified: row.siteImageStatus === 'verified',
        imageUrl: row.siteImageUrl ?? null,
        source: row,
      }))}
      renderDetails={row => <ExistingExpandedTrendCard row={row} />}
      filterControls={<ExistingFilters />}
      statusContent={<ExistingFreshnessNotice />}
    />

**Importante:** cardId distingue las tarjetas, mientras que target_id/revision/explanation/explained_at identifican la explicación compartida. Nunca agrupar por nombre, posición o similitud visual. Si imageVerified no está probado, no mostrar miniicono por mera presencia de una URL o un trabajo LAUNCHED.

## Pruebas

Desde raíz del repo:

    node --test site-patches/ttendencias-compact-top30/model.test.mjs

Cubren búsqueda española con y sin tildes, hashtags, términos agrupados, apertura única, claves duplicadas, URL/estado verificado de imagen y fecha Europe/Madrid.

## Restricción técnica

El conector visible en el chat únicamente permite inspect_top30_images, attach_trend_image y verify_trend_image. Ninguna operación modifica CSS, HTML o componentes del Site. Estos archivos son una implementación integrable, NO una prueba de publicación ni una sustitución por otro Site.


## SINCRONIZACIÓN editorial (prioritaria): mismo Top 30 que TTActualidad

El Site NO debe seleccionar "solo status=explained" ni omitir las fichas
con status=deleted de la colección manual: eso retira una ficha de Listas
pero la app sigue utilizando su explicación reciente al reconstruir Top 30.
Ejemplos comprobados 31/10/2026:

- Halloween: Site antiguo 08:55, nueva explicación editorial ID ab65bc5a5cf7,
  texto 19:29; la nueva está en GitHub con status=deleted y la app la muestra.
- Grimaldo: Site "sin explicar", nueva explicación editorial ID 0e9ddd785dc2,
  texto 23:10, también status=deleted y vigente en Top 30 de la app.

El generador `trends/export_site_top30.py` aplica la selección de
`EditorialStore.buildTop30` de iOS y produce el archivo liviano
`trends/site-top30-current.json`, sin los datos privados del PC ni textos
de ediciones ocultas. Se actualiza en GitHub por
`.github/workflows/ttendencias-site-top30-sync.yml` cuando cambian las
fuentes. El contenido de ese JSON es el contrato público a consumir.

Para INTEGRAR en el Site original:

1. Mantén la fuente de ranking y el diseño actual, pero reemplaza la fuente
   de EXPLICACIONES por
   `https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/site-top30-current.json`.
   Mejor aún, consume ranking y explicaciones de este archivo, pues su
   `rank` y `name` proceden del mismo radar leído al exportar.
2. El helper `site-feed-client.mjs` ofrece `loadCurrentEditorialTop30`
   y `feedToCompactCards` para conectarlo con `CompactTop30.jsx`.
   `source.explanation` y `source.explained_at` ya contienen el texto
   y fecha EXACTOS del ledger del iPhone.
3. Al reconstruir el cuerpo expandido usa los campos `source.explanation`,
   `source.verification_sources`, `source.group_title`, `source.editorial_id`,
   `source.revision` y `source.explained_at`. No mezcles fuentes ni fotos
   de versiones anteriores de un mismo nombre.
4. Actualiza al abrir la página, al regresar de segundo plano y cada ~3 min
   mientras esté visible. Si falla la petición o el JSON tiene 15+ minutos
   de antigüedad, muestra «Datos no actualizados» y la hora; no finjas que
   una explicación anterior es la actual.
5. No edites manualmente `site-top30-current.json`: es salida generada.
   Pruebas: `python3 -m unittest discover -s tests -p 'test_site_top30_export.py' -v`
   y `node --test site-patches/ttendencias-compact-top30/*.test.mjs`.
6. Conserva Site, URL, todas las imágenes y explicaciones originales;
   «Eliminar imagen IA» sigue expresamente descartado.

**Límite:** GitHub puede publicar el JSON automáticamente, pero ninguna
de las acciones de este chat cambia la fuente de datos DENTRO del Site
de ChatGPT. Sin integrar el consumo de JSON en su editor y publicar,
la web pública seguirá usando el criterio antiguo.
