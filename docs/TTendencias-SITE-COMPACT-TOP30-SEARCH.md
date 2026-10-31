# TTendencias Site original — interfaz compacta y buscador sobre Top 30

**Destino único:** `appgprj_6ae4dcf7d7488191a574e5b649e67370`, URL pública existente `https://ttactualidad-tendencias.rainyraven22.chatgpt.site/`.

**Decisión del usuario (31/10/2026): NO incorporar «Eliminar imagen IA».** No crear ni habilitar esa opción en el Site ni en TTActualidad. No borrar PNGs ni referencias existentes.

Este documento es una **especificación de aplicación al código existente del Site**. Estar en GitHub no cambia ni publica el proyecto de ChatGPT Sites. No se dispone aquí de una operación del conector para modificar el DOM/source del Site; solo inspect/attach/verify imágenes. No presentar esta especificación como una modificación ya desplegada.

## Cambios visibles solicitados

1. **Buscador compacto y reubicado.** Mover el buscador actual, con la MISMA funcionalidad de filtrado, para que aparezca **inmediatamente antes** del título «El top 30, explicado» o de la lista Top 30, no en la cabecera/hero ni debajo de las fichas. No crear dos buscadores.
   - Tamaño objetivo de escritorio: ancho máximo ~320 px, altura 36–40 px. Alineación al comienzo del contenido de Top 30.
   - Móvil: ancho 100% del contenedor (sin desbordar); conservar teclado de búsqueda, etiqueta accesible y foco visible.
   - Si existen selectores/filtros de estado, conservarlos junto al buscador o inmediatamente debajo sin crear barras gigantes.
2. **Top 30 plegado en filas de una sola línea.** Por defecto, cada fila visible contiene en este orden: puesto `01–30`, nombre completo elidido visualmente sin cambiar su dato, **última fecha/hora de explicación** o «Pendiente», mini-icono discreto de imagen solo cuando la imagen **IA original está asociada y disponible**, y un indicador desplegar.
   - No usar el color de antigüedad como una segunda fila. Si se conservan códigos visuales, usar un punto/borde mínimo con texto accesible.
   - No equiparar icono de foto de archivo, trabajo lanzado, imagen generada pendiente o imagen inexistente con una IA verificada.
   - Si la tendencia está agrupada, conservar identificación del grupo y su explicación compartida; no reescribir originales ni depender del nombre.
3. **Acordeón de apertura única.** Mantener en estado UI **un único identificador editorial abierto** (no un booleano en cada tarjeta); pulsar otra fila abre esa tarjeta y cierra la anterior; pulsar de nuevo la abierta la cierra. `aria-expanded`, `aria-controls`, activación mediante Enter/Espacio y foco visible. No abrir ninguna ficha al recargar salvo decisión explícita.
4. **Ficha desplegada.** Mostrar explicación literal, fecha, remate separado, agrupación, imagen IA actual si existe y acciones editoriales actuales; preservar enlaces de fuentes, acciones de copiar/buscar/compartir y los textos ya publicados. En falta de explicación mostrar «En investigación» o el estado editorial real, sin inventar contenido.
5. **No restituir «Próximas tendencias».** Mantener actualización, antigüedad y aviso de estado de los datos. No modificar X, Telegram, TTiTTulares, PC ni sistemas de imágenes.

## CSS de referencia (adaptar a nombres REALES de clases del Site)

```css
/* La colocación se cambia en el árbol de componentes, NO con position:absolute. */
.tt-top30-search {
  display: flex; align-items: center; flex-wrap: wrap;
  gap: .5rem; margin: 0 0 .8rem; max-width: 100%;
}
.tt-top30-search input[type="search"] {
  box-sizing: border-box; width: min(100%, 320px);
  min-width: 0; min-height: 38px;
  padding: .45rem .8rem; border-radius: .6rem;
  font: inherit; font-size: .9rem;
}
.tt-top30-search input[type="search"]:focus-visible,
.tt-top30-card__toggle:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
.tt-top30-card__toggle {
  width: 100%; display: grid;
  grid-template-columns: 2.2rem minmax(0, 1fr) auto 1rem auto;
  align-items: center; gap: .5rem;
  padding: .55rem .65rem; text-align: left;
  border: 0; background: transparent; color: inherit; cursor: pointer;
}
.tt-top30-card__name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tt-top30-card__time { white-space: nowrap; font-size: .75rem; opacity: .7; }
.tt-top30-card__image { width: .8rem; height: .8rem; flex: none; }
.tt-top30-card__content[hidden] { display: none; }
@media (max-width: 540px) {
  .tt-top30-search input[type="search"] { width: 100%; max-width: none; }
  .tt-top30-card__toggle { grid-template-columns: 1.8rem minmax(0,1fr) auto auto; gap: .35rem; }
  .tt-top30-card__time { font-size: .68rem; max-width: 8.4rem; overflow: hidden; text-overflow: ellipsis; }
}
```

La cuadrícula es orientativa; si los textos de fecha ocupan demasiado espacio en un iPhone estrecho, usar formato de fecha/hora compacto manteniendo la fecha completa en `title`/etiqueta accesible. No acortar la explicación guardada.

## Integración del estado (pseudocódigo React/Site)

```jsx
const [openEditorialId, setOpenEditorialId] = useState(null);
const [search, setSearch] = useState("");

<section id="tendencias">
  <div className="tt-top30-search">
    <label htmlFor="tt-top30-query">Buscar tendencias</label>
    <input id="tt-top30-query" type="search" value={search}
           onChange={e => setSearch(e.target.value)} />
  </div>
  <h2>El top 30, explicado.</h2>
  {filteredTop30.map(row => {
    const key = row.editorialTargetId ?? row.id; // resolver datos reales; NO por rank/nombre
    const isOpen = openEditorialId === key;
    return (
      <article key={row.stableCardId}>
        <button className="tt-top30-card__toggle"
                type="button" aria-expanded={isOpen}
                aria-controls={`trend-details-${row.stableCardId}`}
                onClick={() => setOpenEditorialId(isOpen ? null : key)}>
          <span>{String(row.rank).padStart(2, "0")}</span>
          <span className="tt-top30-card__name">{row.name}</span>
          <time className="tt-top30-card__time">{row.lastExplainedLabel ?? "Pendiente"}</time>
          {row.siteImageVerified && <span className="tt-top30-card__image" aria-label="Imagen IA">▧</span>}
          <span aria-hidden="true">{isOpen ? "⌃" : "⌄"}</span>
        </button>
        <div id={`trend-details-${row.stableCardId}`} hidden={!isOpen}
             className="tt-top30-card__content">
          {/* reutilizar el contenido y acciones ya existentes, sin alterar editoriales */}
        </div>
      </article>
    );
  })}
</section>
```

**Atención a agrupaciones:** si dos filas comparten identidad editorial, no usar esa identidad como clave de React de ambas; mantener `stableCardId` distinto para cada fila y un `openCardId` por fila, y resolver el contexto editorial agrupado solo para los datos asociados. El ejemplo debe adaptarse a eso antes de publicar.

## Verificaciones exigidas antes de comunicar publicado

- Desktop y móvil: buscador de altura compacta justo encima del título/lista Top 30; no duplicado.
- Búsqueda filtra correctamente por nombres/hashtags y permite limpiar texto.
- 30 filas iniciales plegadas; solo una desplegada tras alternar entre dos; no se superponen paneles.
- Fecha/hora visibles y correctas; IA iconificada solamente si realmente asociada/verificada.
- Agrupación conserva el texto original y el remate; enlaces y botones funcionan.
- 0 modificaciones de imágenes, catálogo, explicaciones, revisiones o programación.
- Verificar en la URL pública EXISTENTE después de publicar y no afirmar éxito si no hay editor disponible.

## Límite técnico conocido

El conector `TTendencias · TTActualidad` visible en el chat únicamente declara `inspect_top30_images`, `attach_trend_image` y `verify_trend_image`. No acepta alterar CSS/JS o el árbol de componentes. Este documento prepara la implementación para el **editor del mismo proyecto Sites**, pero no instala los cambios.
