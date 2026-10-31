// Safe, presentation-only helpers. No network, mutations or editorial writes.
export const SITE_ORIGIN = 'https://ttactualidad-tendencias.rainyraven22.chatgpt.site';

export function normalizeSearch(value) {
  return String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLocaleLowerCase('es-ES').trim();
}

export function matchesTop30Query(card, query) {
  const words = normalizeSearch(query).split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const haystack = normalizeSearch([card.name, card.groupLabel, ...(card.searchTerms ?? [])].join(' '));
  return words.every(word => haystack.includes(word));
}

export function validateCards(cards) {
  if (!Array.isArray(cards)) throw new TypeError('Top30 must be an array');
  const ids = new Set();
  for (const card of cards) {
    if (!card || typeof card !== 'object' || typeof card.cardId !== 'string' || !card.cardId.trim()) {
      throw new TypeError('Each card needs its own stable cardId');
    }
    if (ids.has(card.cardId)) throw new TypeError('Duplicate cardId in Top30: ' + card.cardId);
    ids.add(card.cardId);
    if (!Number.isInteger(card.rank) || card.rank < 1 || card.rank > 30) {
      throw new TypeError('Invalid Top30 rank for ' + card.cardId);
    }
  }
  return cards;
}

export function filteredTop30(cards, query) {
  return validateCards(cards).filter(row => matchesTop30Query(row, query));
}

export function nextOpenCardId(currentCardId, clickedCardId) {
  if (typeof clickedCardId !== 'string' || !clickedCardId) throw new TypeError('Missing clicked cardId');
  return currentCardId === clickedCardId ? null : clickedCardId;
}

export function isVerifiedSiteImage(card) {
  if (card.imageVerified !== true || typeof card.imageUrl !== 'string') return false;
  try {
    const url = new URL(card.imageUrl, SITE_ORIGIN);
    return url.protocol === 'https:' && url.origin === SITE_ORIGIN &&
      url.pathname.startsWith('/images/ttendencias/') && /\.png$/i.test(url.pathname) &&
      !url.username && !url.password && !url.search && !url.hash;
  } catch { return false; }
}

export function formatMadridExplainedAt(value) {
  if (typeof value !== 'string' || !value.trim()) return 'Pendiente';
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return 'Pendiente';
  return new Intl.DateTimeFormat('es-ES', {
    timeZone: 'Europe/Madrid', day: '2-digit', month: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(date).replace(',', '');
}
