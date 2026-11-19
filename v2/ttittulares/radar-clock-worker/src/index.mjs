// A separate, cron-only Cloudflare Worker. It cannot publish news or mutate
// the editorial ledger. A stale radar authorizes only one workflow_dispatch.
const REPO = 'fabricelop/europapress-rss';
const WORKFLOW = 'ttittulares-v2-radar-clock.yml';
const SUMMARY_URL = `https://raw.githubusercontent.com/${REPO}/ttactualidad-v2-radar-live/v2/ttittulares/state/radar/live-summary.json`;
const API_URL = `https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}`;
const STALE_MS = 20 * 60_000;
const RECENT_MS = 10 * 60_000;

function githubHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'TTActualidadV2RadarClock',
  };
}

function observedAt(value, now) {
  if (value?.project !== 'ttittulares-v2' ||
      value.kind !== 'independent_radar_summary' ||
      typeof value.observed_at !== 'string') {
    throw Error('RADAR_SUMMARY_INVALID');
  }
  const timestamp = Date.parse(value.observed_at);
  if (!Number.isFinite(timestamp) || timestamp > now.getTime() + 300_000) {
    throw Error('RADAR_SUMMARY_TIMESTAMP_INVALID');
  }
  return timestamp;
}

export async function checkAndDispatch(env, {
  fetcher = fetch,
  now = new Date(),
  logger = console,
} = {}) {
  const token = env?.GITHUB_DISPATCH_TOKEN;
  if (typeof token !== 'string' || token.length < 20) {
    throw Error('RADAR_DISPATCH_SECRET_MISSING');
  }

  const summaryResponse = await fetcher(SUMMARY_URL, {
    headers: {Accept: 'application/json', 'Cache-Control': 'no-cache'},
    cf: {cacheTtl: 0, cacheEverything: false},
  });
  if (!summaryResponse.ok) throw Error('RADAR_SUMMARY_UNAVAILABLE');
  const summary = await summaryResponse.json();
  const ageMs = Math.max(0, now.getTime() - observedAt(summary, now));
  const ageMinutes = Math.floor(ageMs / 60_000);
  if (ageMs < STALE_MS) {
    logger.log('TTN2_RADAR_EXTERNAL_CLOCK_FRESH', ageMinutes);
    return {state: 'fresh', age_minutes: ageMinutes, dispatched: false};
  }

  // Never enqueue another run while a recent or still-running one exists.
  // The GitHub workflow also has CAS-fenced persistence and concurrency.
  const runResponse = await fetcher(`${API_URL}/runs?per_page=5&branch=main`, {
    headers: githubHeaders(token),
  });
  if (!runResponse.ok) throw Error('RADAR_WORKFLOW_STATUS_UNAVAILABLE');
  const runs = (await runResponse.json()).workflow_runs;
  if (!Array.isArray(runs)) throw Error('RADAR_WORKFLOW_RUNS_INVALID');
  const hasActiveOrRecent = runs.some(run => {
    if (run?.head_branch !== 'main') return false;
    const started = Date.parse(run.created_at);
    if (!Number.isFinite(started) || started > now.getTime() + 300_000) return false;
    const since = now.getTime() - started;
    return since < RECENT_MS || (
      ['queued', 'in_progress', 'waiting', 'pending', 'requested'].includes(run.status)
      && since < 30 * 60_000
    );
  });
  if (hasActiveOrRecent) {
    logger.warn('TTN2_RADAR_CLOCK_STALE_BUT_ALREADY_RUNNING', ageMinutes);
    return {state: 'run_already_scheduled', age_minutes: ageMinutes, dispatched: false};
  }

  const dispatch = await fetcher(`${API_URL}/dispatches`, {
    method: 'POST',
    headers: {...githubHeaders(token), 'Content-Type': 'application/json'},
    body: JSON.stringify({ref: 'main'}),
  });
  if (dispatch.status !== 204) {
    throw Error('RADAR_WORKFLOW_DISPATCH_NOT_ACCEPTED');
  }
  logger.warn('TTN2_RADAR_CLOCK_DISPATCH_ACCEPTED', ageMinutes);
  return {state: 'dispatched', age_minutes: ageMinutes, dispatched: true};
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(checkAndDispatch(env));
  },
  async fetch() {
    return new Response('Not found', {status: 404});
  },
};
