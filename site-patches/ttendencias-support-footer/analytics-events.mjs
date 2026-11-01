import {METRIC_EVENTS, allowedMetric} from './footer-model.mjs';

/**
 * Anonymous, low-cardinality events. No search terms, comments, emails, IPs,
 * session IDs, user names or fingerprinting. Tracker is optional.
 */
export function trackSiteEvent(eventName, detail = {}, tracker = globalThis.umami) {
  if (!allowedMetric(eventName) || !tracker || typeof tracker.track !== 'function') return false;
  const rank = Number.isInteger(detail.rank) && detail.rank >= 1 && detail.rank <= 30
    ? detail.rank : undefined;
  try {
    if (rank !== undefined) tracker.track(eventName, {rank});
    else tracker.track(eventName);
    return true;
  } catch {
    return false; // analytics must never block the website
  }
}

/**
 * Call from the EXISTING trend open handler, only when opening, not closing:
 *   trackSiteEvent(METRIC_EVENTS.expand, {rank: trend.rank});
 *
 * Call once when visitor deliberately searches, not on each keystroke:
 *   trackSiteEvent(METRIC_EVENTS.search);
 *
 * To configure pageviews + footer button events, use the exact tracking
 * <script> tag Umami provides for YOUR account (Website ID is not a secret).
 * Do NOT copy a placeholder tracking ID, add cookies, or track text fields.
 */
export {METRIC_EVENTS};
