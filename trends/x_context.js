'use strict';
// Investigación opcional: no toca cola, textos, decisiones, imágenes ni publicación.
// Basado en el acceso Playwright de SeLoRecordamos, sin importar su proceso con efectos.
const fs = require('node:fs'), path = require('node:path');
const QUEUE = process.env.TT_X_QUEUE_FILE || path.join(__dirname, 'editorial-queue.json');
const OUT = process.env.TT_X_OUTPUT_FILE || path.join(__dirname, 'x-context-evidence.json');
const LOCAL = process.env.TT_X_EXECUTION_MODE === 'windows';
const SOURCE = LOCAL ? 'x_recent_posts_windows' : 'x_recent_posts';
const HOUR = 3600000, LIMIT = 6, POST_LIMIT = 8;
function readJSON(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return fallback; } }
function cleanName(v) { return String(v || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 90); }
function key(x) { return String(x.id || '') + ':' + String(x.revision ?? 0); }
function recentDate(s, now, max) { const d = Date.parse(String(s || '')); return Number.isFinite(d) && d <= now + 300000 && d >= now - max; }
function makeSearchUrl(name) {
  const q = cleanName(name).replace(/["\\]/g, '');
  if (!q) throw Error('empty term');
  return 'https://x.com/search?q=' + encodeURIComponent('"' + q + '"') + '&src=typed_query&f=live';
}
function chooseTargets(queue, cache, now = Date.now(), limit = LIMIT, source = 'x_recent_posts') {
  // Circuit breaker global: un 403/429 de X en el runner no justifica seguir
  // consultando otros nombres desde la misma IP. Reintentar más adelante.
  const previousItems = Array.isArray(cache.items) ? cache.items : [];
  if (previousItems.some(x => x && (!x.source || x.source === source) &&
      (x.http_status === 403 || x.http_status === 429) &&
      recentDate(x.searched_at, now, x.http_status === 403 ? 12 * HOUR : 4 * HOUR))) return [];
  const old = new Map(previousItems.filter(x => x && (!x.source || x.source === source)).map(x => [key(x), x]));
  const chosen = [], seen = new Set();
  for (const x of (Array.isArray(queue.items) ? queue.items : [])) {
    if (!x || !['preparing', 'update', 'problematic'].includes(x.status)) continue;
    const id = String(x.id || ''), name = cleanName(x.name), rev = Number(x.revision);
    if (!/^[A-Za-z0-9_-]{6,80}$/.test(id) || !name || !Number.isSafeInteger(rev) || rev < 0) continue;
    const k = id + ':' + rev;
    if (seen.has(k)) continue;
    seen.add(k);
    const p = old.get(k);
    if (p && cleanName(p.name) === name && recentDate(p.searched_at, now,
      p.status === 'ok' ? HOUR : p.status === 'empty' ? 1500000 : 900000)) continue;
    chosen.push({ id, revision: rev, name });
    if (chosen.length >= Math.min(LIMIT, Math.max(1, limit))) break;
  }
  return chosen;
}
function validPost(p, now = Date.now()) {
  return !!p && /^https:\/\/x\.com\/[A-Za-z0-9_]{1,15}\/status\/\d+$/.test(String(p.url || ''))
    && typeof p.text === 'string' && !!p.text.trim() && recentDate(p.datetime, now, 48 * HOUR);
}
function usableEvidence(cache, request, now = Date.now()) {
  const e = (Array.isArray(cache.items) ? cache.items : []).find(x =>
    x && String(x.id) === String(request.id) && Number(x.revision) === Number(request.revision)
    && cleanName(x.name) === cleanName(request.name));
  if (!e || e.status !== 'ok' || !recentDate(e.searched_at, now, 90 * 60000)) return null;
  const posts = (Array.isArray(e.posts) ? e.posts : []).filter(p => validPost(p, now));
  return posts.length ? { ...e, posts } : null;
}
function assembleEvidence(cache, updates, now = Date.now()) {
  const entries = new Map();
  for (const x of (Array.isArray(cache.items) ? cache.items : [])) {
    if (x && x.id && recentDate(x.searched_at, now, 6 * HOUR)) entries.set(key(x), x);
  }
  for (const x of updates) entries.set(key(x), x);
  return { schema_version: 1, project: 'TTendencias',
    generated_at: new Date(now).toISOString(),
    provenance: 'Partial sample of public X posts, not a fact check or measure of trending volume',
    items: Array.from(entries.values()).slice(-60) };
}
async function extractPosts(page, now) {
  const found = new Map();
  for (let round = 0; round < 3; round++) {
    const tweets = page.locator('article[data-testid="tweet"]');
    const n = Math.min(await tweets.count(), 24);
    for (let i = 0; i < n; i++) {
      const tweet = tweets.nth(i), time = tweet.locator('time').first();
      const body = await tweet.locator('[data-testid="tweetText"]').innerText().catch(() => '');
      const datetime = await time.getAttribute('datetime').catch(() => null);
      const href = await time.locator('xpath=..').getAttribute('href').catch(() => null)
        || await tweet.locator('a[href*="/status/"]').first().getAttribute('href').catch(() => null);
      const match = String(href || '').match(/^\/([A-Za-z0-9_]{1,15})\/status\/(\d+)/);
      if (!match) continue;
      const post = { id: match[2], author: '@' + match[1], datetime,
        url: 'https://x.com/' + match[1] + '/status/' + match[2],
        text: String(body).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 900) };
      if (validPost(post, now)) found.set(post.id, post);
    }
    if (found.size >= POST_LIMIT) break;
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)).catch(() => {});
    await page.waitForTimeout(1000);
  }
  return Array.from(found.values()).slice(0, POST_LIMIT);
}
async function search(context, target) {
  const now = Date.now(), page = await context.newPage();
  const base = { id: target.id, revision: target.revision, name: target.name,
    searched_at: new Date(now).toISOString(), source: SOURCE,
    search_url: makeSearchUrl(target.name), status: 'error', posts: [] };
  let lastError = '', responseStatus = null;
  try {
    let ready = false;
    // Igual que SeLoRecordamos: X puede mostrar tuits aunque su navegación no termine.
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const response = await page.goto(base.search_url, { waitUntil: 'commit', timeout: 22000 });
        responseStatus = response ? response.status() : null;
        await page.locator('main, [data-testid="primaryColumn"], article[data-testid="tweet"]')
          .first().waitFor({ state: 'attached', timeout: 12000 });
        ready = true;
        break;
      } catch (error) {
        lastError = String(error && error.message || error).slice(0, 180);
        const visible = await page.locator('article[data-testid="tweet"]').count().catch(() => 0);
        if (visible > 0 && page.url().startsWith('https://x.com/')) { ready = true; break; }
        if (!attempt) await page.waitForTimeout(1200);
      }
    }
    if (!ready) return { ...base, reason: 'navigation_failed', http_status: responseStatus,
      diagnostic: /timeout/i.test(lastError) ? 'timeout_waiting_for_x_content' : 'x_content_not_available' };
    await page.waitForTimeout(1600);
    if (/\/i\/flow\/login|\/login/.test(page.url())) return { ...base, reason: 'auth_required', http_status: responseStatus };
    if (responseStatus === 403 || responseStatus === 429) return { ...base, reason: 'x_http_restriction', http_status: responseStatus };
    const posts = await extractPosts(page, now);
    return { ...base, status: posts.length ? 'ok' : 'empty', posts, http_status: responseStatus };
  } catch (_) { return { ...base, reason: 'unexpected_x_error', http_status: responseStatus }; }
  finally { await page.close().catch(() => {}); }
}
async function run() {
  const queue = readJSON(QUEUE, { items: [] }), current = readJSON(OUT, { items: [] });
  const targets = chooseTargets(queue, current, Date.now(), LIMIT, SOURCE);
  if (process.argv.includes('--plan')) { console.log(JSON.stringify({ targets })); return; }
  if (!targets.length) { console.log('TT_X_CONTEXT no_pending_targets'); return; }
  const token = process.env.X_AUTH_TOKEN || '', ct0 = process.env.X_CT0 || '';
  if (!token || !ct0) { console.log('TT_X_CONTEXT session_secrets_unavailable; normal editorial unaffected'); return; }
  const { chromium } = require('playwright');
  const launchOptions = { headless: true };
  const chromePath = process.env.TT_X_CHROME_PATH || (process.platform === 'win32'
    ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' : '');
  if (chromePath && fs.existsSync(chromePath)) launchOptions.executablePath = chromePath;
  const browser = await chromium.launch(launchOptions);
  const updates = [];
  try {
    const context = await browser.newContext({ locale: 'es-ES', timezoneId: 'Europe/Madrid',
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36' });
    await context.addCookies([
      { name: 'auth_token', value: token, domain: '.x.com', path: '/', secure: true, httpOnly: true, sameSite: 'None' },
      { name: 'ct0', value: ct0, domain: '.x.com', path: '/', secure: true, httpOnly: false, sameSite: 'Lax' }
    ]);
    for (const target of targets) {
      const result = await search(context, target);
      updates.push(result);
      console.log('TT_X_CONTEXT id=' + target.id + ' rev=' + target.revision + ' status=' + result.status + ' posts=' + result.posts.length);
    }
    await context.close();
  } finally { await browser.close(); }
  const temp = OUT + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(assembleEvidence(current, updates), null, 2) + '\n');
  fs.renameSync(temp, OUT);
}
if (require.main === module) run().catch(e => { console.error('TT_X_CONTEXT failed: ' + String(e.message || e)); process.exitCode = 1; });
module.exports = { cleanName, makeSearchUrl, chooseTargets, validPost, usableEvidence, assembleEvidence };
