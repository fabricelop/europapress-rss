import test from 'node:test';
import assert from 'node:assert/strict';
import {KOFI_URL, FEEDBACK_EMAIL, MAX_SUGGESTION_LENGTH, cleanSuggestion,
  buildFeedbackMailto, isSafeSupportLink, allowedMetric, METRIC_EVENTS} from './footer-model.mjs';

test('Ko-fi link is exact voluntary support destination; never personal PayPal data', () => {
  assert.equal(KOFI_URL, 'https://ko-fi.com/ttactualidad');
  assert(isSafeSupportLink(KOFI_URL));
  assert.equal(isSafeSupportLink('https://ko-fi.com/other'), false);
});
test('feedback mailto opens visitor email client, sends no data to analytics/server', () => {
  const uri = buildFeedbackMailto('   Me gustaría mejorar la búsqueda   ');
  assert(uri.startsWith('mailto:' + FEEDBACK_EMAIL + '?subject='));
  assert(uri.includes(encodeURIComponent('Me gustaría mejorar la búsqueda')));
  assert.equal(buildFeedbackMailto(' \n '), null);
});
test('feedback text is bounded and URL-encoded; cannot append extra mail headers', () => {
  const uri = buildFeedbackMailto('Hola\r\nBcc: usuario@example.com & asunto=');
  assert.equal(uri.split('?').length, 2);
  assert(!uri.includes('&Bcc='));
  assert.equal(cleanSuggestion('x'.repeat(2500)).length, MAX_SUGGESTION_LENGTH);
});
test('only anonymous low-cardinality interaction events are tracked', () => {
  assert(allowedMetric(METRIC_EVENTS.donation));
  assert(allowedMetric(METRIC_EVENTS.expand));
  assert(!allowedMetric('Buscar: término secreto'));
});
