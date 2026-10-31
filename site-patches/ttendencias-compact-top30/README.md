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
