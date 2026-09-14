const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  const query = '"recordadme" OR "que alguien me recuerde"';
  const url = `https://x.com/search?q=${encodeURIComponent(query)}&src=typed_query&f=live`;
  const baseDir = path.join(__dirname);
  const outDir = path.join(baseDir, 'debug');
  const stateDir = path.join(baseDir, 'runtime');
  const seenFile = path.join(stateDir, 'seen.json');
  fs.mkdirSync(outDir, { recursive: true });
  fs.mkdirSync(stateDir, { recursive: true });

  const authToken = process.env.X_AUTH_TOKEN || '';
  const ct0 = process.env.X_CT0 || '';
  const chromePath = process.env.SR_CHROME_PATH || (process.platform === 'win32'
    ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe'
    : '');
  const headless = process.env.SR_HEADLESS === '1';

  let seen = {};
  try {
    seen = JSON.parse(fs.readFileSync(seenFile, 'utf8'));
  } catch (_) {
    seen = {};
  }

  const launchOptions = { headless };
  if (chromePath && fs.existsSync(chromePath)) launchOptions.executablePath = chromePath;

  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({
    locale: 'es-ES',
    timezoneId: 'Europe/Madrid',
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
  });

  if (authToken && ct0) {
    await context.addCookies([
      { name: 'auth_token', value: authToken, domain: '.x.com', path: '/', httpOnly: true, secure: true, sameSite: 'None' },
      { name: 'ct0', value: ct0, domain: '.x.com', path: '/', httpOnly: false, secure: true, sameSite: 'Lax' }
    ]);
  }

  const page = await context.newPage();
  const result = {
    query,
    search_url: url,
    fetched_at: new Date().toISOString(),
    authenticated_cookie_pair_present: Boolean(authToken && ct0),
    final_url: null,
    title: null,
    extracted: 0,
    already_seen: 0,
    rejected: [],
    candidates: [],
    status: 'unknown',
    note: null
  };

  const normalize = (text) => text
    .toLocaleLowerCase('es-ES')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  const rejectReason = (text) => {
    const t = normalize(text);

    if (/\b(si|cuando)\s+(manana\s+)?(desaparezco|muero|fallezco|palmo)\b/.test(t)) {
      return 'memorial/no es una petición de recordatorio';
    }
    if (/\brecordadme\s+como\s+(el|la|los|las|quien)\b/.test(t)) {
      return '“recordadme como…” no es una petición de recordatorio';
    }

    const consultationPatterns = [
      /\brecordadme[,:]?\s+(quien|cual|donde|como|por que|porque)\b/,
      /\brecordadme[,:]?\s+en\s+(que|cual)\b/,
      /\brecordadme[,:]?\s+en\s+esta\b/,
      /\bque alguien me recuerde\s+(quien|cual|donde|como|por que|porque)\b/,
      /\bque alguien me recuerde\s+de\s+(donde|que|cual)\b/,
      /\bque alguien me recuerde\s+(una|un)\s+sol[ao]\b/
    ];
    if (consultationPatterns.some(r => r.test(t))) {
      return 'pregunta/consulta, no recordatorio futuro';
    }

    if (/\brecordadme[,:]?\s+que\s+(quien|que|cual|donde|como)\b/.test(t)) {
      return 'pregunta/consulta, no recordatorio futuro';
    }

    return null;
  };

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(10000);
    result.final_url = page.url();
    result.title = await page.title();

    const loginVisible = await page.locator('text=Inicia sesión').first().isVisible().catch(() => false);
    const tweetArticles = page.locator('article[data-testid="tweet"]');
    const count = await tweetArticles.count();
    const extracted = [];

    for (let i = 0; i < Math.min(count, 30); i++) {
      const article = tweetArticles.nth(i);
      const text = await article.locator('[data-testid="tweetText"]').innerText().catch(() => '');
      const timeEl = article.locator('time').first();
      const datetime = await timeEl.getAttribute('datetime').catch(() => null);
      const timeHref = await timeEl.locator('xpath=..').getAttribute('href').catch(() => null);
      const links = await article.locator('a[href*="/status/"]').evaluateAll(els => els.map(a => a.getAttribute('href')).filter(Boolean)).catch(() => []);
      const statusPath = (timeHref && /^\/[^/]+\/status\/\d+/.test(timeHref))
        ? timeHref
        : links.find(h => /^\/[^/]+\/status\/\d+/.test(h));
      if (!text || !statusPath) continue;
      const m = statusPath.match(/^\/([^/]+)\/status\/(\d+)/);
      if (!m) continue;
      const [, user, id] = m;
      if (extracted.some(t => t.id === id)) continue;
      extracted.push({ id, user: `@${user}`, text, datetime, url: `https://x.com/${user}/status/${id}` });
    }

    result.extracted = extracted.length;

    for (const tweet of extracted) {
      if (seen[tweet.id]) {
        result.already_seen++;
        continue;
      }
      const reason = rejectReason(tweet.text);
      seen[tweet.id] = { first_seen_at: result.fetched_at, url: tweet.url, rejected: Boolean(reason) };
      if (reason) {
        result.rejected.push({ ...tweet, reason });
        continue;
      }
      result.candidates.push(tweet);
    }

    fs.writeFileSync(seenFile, JSON.stringify(seen, null, 2), 'utf8');

    if (result.candidates.length) {
      result.status = 'ok';
      result.note = `${result.candidates.length} candidatos nuevos de ${result.extracted} tuits extraídos.`;
    } else if (!authToken || !ct0) {
      result.status = 'missing_secrets';
      result.note = 'Faltan X_AUTH_TOKEN y/o X_CT0 en las variables de entorno.';
    } else if (loginVisible || /login|i\/flow\/login/.test(result.final_url || '')) {
      result.status = 'auth_required';
      result.note = 'Las cookies no han autenticado la sesión de X o han caducado.';
    } else {
      result.status = 'no_new_candidates';
      result.note = `Sin candidatos nuevos. Extraídos: ${result.extracted}; ya vistos: ${result.already_seen}; descartados: ${result.rejected.length}.`;
    }

    await page.screenshot({ path: path.join(outDir, 'search.png'), fullPage: true });
    fs.writeFileSync(path.join(outDir, 'page.html'), await page.content(), 'utf8');
  } catch (e) {
    result.status = 'error';
    result.note = String(e && e.stack ? e.stack : e);
  } finally {
    fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(result, null, 2), 'utf8');
    console.log(JSON.stringify(result, null, 2));
    await browser.close();
  }
})();
