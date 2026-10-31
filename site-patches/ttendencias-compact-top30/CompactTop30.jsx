import React, { useEffect, useMemo, useState } from 'react';
import {
  filteredTop30, formatMadridExplainedAt,
  isVerifiedSiteImage, nextOpenCardId,
} from './model.mjs';
import './compact-top30.css';

/**
 * Integration in the ORIGINAL Site only. Do not mount a second Top30.
 * Adapt the existing Top30 data once into cards of shape:
 * {cardId,rank,name,explainedAt,groupLabel?,searchTerms?,imageVerified,imageUrl,source}
 * Use the existing expanded-card implementation as renderDetails(card.source).
 * cardId uniquely identifies each visible ROW; editorial group ID is shared data,
 * never the React key or the accordion key.
 */
export default function CompactTop30({
  cards,
  renderDetails,
  query,
  onQueryChange,
  filterControls = null,
  statusContent = null,
}) {
  const [localQuery, setLocalQuery] = useState('');
  const [openCardId, setOpenCardId] = useState(null);
  const search = query === undefined ? localQuery : query;
  const onSearch = onQueryChange ?? setLocalQuery;
  const rows = useMemo(() => filteredTop30(cards, search), [cards, search]);
  useEffect(() => setOpenCardId(null), [search]);
  const visibleOpen = rows.some(row => row.cardId === openCardId) ? openCardId : null;

  return (
    <section className="tt-top30" id="tendencias" aria-labelledby="tt-top30-heading">
      <div className="tt-top30__search-block">
        <label className="tt-top30__search-label" htmlFor="tt-top30-search">Buscar tendencias</label>
        <div className="tt-top30__search-row">
          <input id="tt-top30-search" type="search" className="tt-top30__search"
            value={search} onChange={event => onSearch(event.target.value)}
            placeholder="Busca un tema o hashtag…" autoComplete="off" />
          {search && <button type="button" className="tt-top30__clear"
            onClick={() => onSearch('')} aria-label="Limpiar búsqueda">×</button>}
          {filterControls}
        </div>
      </div>
      <div className="tt-top30__heading-row">
        <h2 id="tt-top30-heading">El top 30, explicado.</h2>
        <p>Toca una tendencia para leerla</p>
      </div>
      {statusContent}
      <ol className="tt-top30__list" aria-label="Top 30 de tendencias en España">
        {rows.map(card => {
          const isOpen = visibleOpen === card.cardId;
          const detailsId = 'tt-top30-details-' + encodeURIComponent(card.cardId);
          const dateLabel = formatMadridExplainedAt(card.explainedAt);
          const verifiedImage = isVerifiedSiteImage(card);
          return (
            <li key={card.cardId} className={'tt-top30__card' + (isOpen ? ' is-open' : '')}>
              <button type="button" className="tt-top30__toggle" aria-expanded={isOpen}
                aria-controls={detailsId}
                onClick={() => setOpenCardId(current => nextOpenCardId(current, card.cardId))}>
                <span className="tt-top30__rank">{String(card.rank).padStart(2, '0')}</span>
                <span className="tt-top30__name" title={card.name}>{card.name}</span>
                <time className="tt-top30__date" title={card.explainedAt || 'Pendiente de explicación'}
                  dateTime={card.explainedAt || undefined}>{dateLabel}</time>
                {verifiedImage && <svg aria-label="Imagen IA disponible" role="img" className="tt-top30__image-indicator"
                  width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                  strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
                  <rect x="3" y="3" width="18" height="18" rx="3" />
                  <circle cx="8.5" cy="8.5" r="1.6" />
                  <path d="m4 18 5.5-5.5 3.5 3.5 3-3 5 5" />
                </svg>}
                {!verifiedImage && <span className="tt-top30__image-placeholder" aria-hidden="true" />}
                <span aria-hidden="true" className="tt-top30__chevron">⌄</span>
              </button>
              {isOpen && <div id={detailsId} className="tt-top30__details">
                {renderDetails(card.source, card)}
              </div>}
            </li>
          );
        })}
      </ol>
      {rows.length === 0 && <p className="tt-top30__empty">No hay tendencias que coincidan con la búsqueda.</p>}
    </section>
  );
}
