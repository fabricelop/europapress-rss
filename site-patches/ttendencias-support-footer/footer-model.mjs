// Public, non-commercial support and feedback metadata for the ORIGINAL Site.
export const KOFI_URL = 'https://ko-fi.com/ttactualidad';
export const FEEDBACK_EMAIL = 'ttactualidad@gmail.com';
export const MAX_SUGGESTION_LENGTH = 1500;
const SUBJECT = 'Sugerencia para mejorar TTActualidad';

export function cleanSuggestion(value) {
  return String(value ?? '').replace(/\r\n?/g, '\n').trim().slice(0, MAX_SUGGESTION_LENGTH);
}

export function buildFeedbackMailto(value) {
  const message = cleanSuggestion(value);
  if (!message) return null;
  const body = 'Hola, TTActualidad:\n\n' + message + '\n\nEnviado desde la página web de TTendencias.';
  return 'mailto:' + FEEDBACK_EMAIL +
    '?subject=' + encodeURIComponent(SUBJECT) +
    '&body=' + encodeURIComponent(body);
}

export function isSafeSupportLink(url) {
  return url === KOFI_URL;
}

// Analytics sends only coarse, named actions. No search text, names, e-mails,
// free text, IP, fingerprint, persistent identifiers or individual visitor IDs.
export const METRIC_EVENTS = Object.freeze({
  donation: 'Donacion Ko-fi',
  feedback: 'Abrir correo sugerencia',
  expand: 'Abrir ficha tendencia',
  search: 'Usar buscador Top30',
  source: 'Abrir fuente editorial'
});

export function allowedMetric(name) {
  return Object.values(METRIC_EVENTS).includes(name);
}
