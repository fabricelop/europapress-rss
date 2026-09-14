const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  const query = '"recordadme" OR "que alguien me recuerde"';
  const url = `https://x.com/search?q=${encodeURIComponent(query)}&src=typed_query&f=live`;
  const baseDir = path.join(__dirname);
  const outDir = path.join(baseDir, 'debug');
  const stateDir = path.join(baseDir, 'runtime');
  const candidatesDir = path.join(baseDir, 'candidates');
  const outboxFile = path.join(baseDir, 'telegram-outbox.json');
  const seenFile = path.join(stateDir, 'seen.json');
  fs.mkdirSync(outDir, { recursive: true });
  fs.mkdirSync(stateDir, { recursive: true });
  fs.mkdirSync(candidatesDir, { recursive: true });

  const authToken = process.env.X_AUTH_TOKEN || '';
  const ct0 = process.env.X_CT0 || '';
  const chromePath = process.env.SR_CHROME_PATH || (process.platform === 'win32'
    ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe'
    : '');
  const headless = process.env.SR_HEADLESS === '1';
  const backfillDays = Math.max(0, Number(process.env.SR_BACKFILL_DAYS || '0') || 0);
  const backfillCutoff = backfillDays > 0 ? Date.now() - backfillDays * 86400000 : null;

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
    mode: backfillDays > 0 ? `backfill_${backfillDays}d` : 'incremental',
    final_url: null,
    title: null,
    extracted: 0,
    scroll_rounds: 0,
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

  const readVisibleTweets = async () => {
    const articles = page.locator('article[data-testid="tweet"]');
    const count = await articles.count();
    const tweets = [];

    for (let i = 0; i < count; i++) {
      const article = articles.nth(i);
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
      tweets.push({ id, user: `@${user}`, text, datetime, url: `https://x.com/${user}/status/${id}` });
    }

    return tweets;
  };

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(7000);
    result.final_url = page.url();
    result.title = await page.title();

    const loginVisible = await page.locator('text=Inicia sesión').first().isVisible().catch(() => false);
    const extractedMap = new Map();
    let stableRounds = 0;
    let seenBoundaryRounds = 0;
    const maxScrollRounds = backfillDays > 0 ? 80 : 12;

    for (let round = 0; round < maxScrollRounds; round++) {
      const visible = await readVisibleTweets();
      const before = extractedMap.size;
      for (const tweet of visible) extractedMap.set(tweet.id, tweet);
      const added = extractedMap.size - before;
      result.scroll_rounds = round + 1;

      if (added === 0) stableRounds++;
      else stableRounds = 0;

      if (backfillDays > 0) {
        const dated = visible
          .map(t => t.datetime ? Date.parse(t.datetime) : NaN)
          .filter(Number.isFinite);
        if (dated.length && Math.min(...dated) <= backfillCutoff) break;
        if (stableRounds >= 4) break;
      } else {
        const visibleIds = visible.map(t => t.id);
        const reachedSeenBoundary = visibleIds.some(id => Boolean(seen[id]));
        if (reachedSeenBoundary) seenBoundaryRounds++;
        else seenBoundaryRounds = 0;

        if (seenBoundaryRounds >= 2) break;
        if (stableRounds >= 3) break;
      }

      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.waitForTimeout(1400);
    }

    let extracted = Array.from(extractedMap.values());
    if (backfillDays > 0) {
      extracted = extracted.filter(t => !t.datetime || Date.parse(t.datetime) >= backfillCutoff);
    }
    result.extracted = extracted.length;

    for (const tweet of extracted) {
      if (seen[tweet.id]) {
        result.already_seen++;
        continue;
      }
      const reason = rejectReason(tweet.text);
      seen[tweet.id] = { first_seen_at: result.fetched_at, url: tweet.url, rejected: Boolean(reason), datetime: tweet.datetime || null };
      if (reason) {
        result.rejected.push({ ...tweet, reason });
        continue;
      }
      const candidate = {
        ...tweet,
        first_seen_at: result.fetched_at,
        status: 'pending'
      };
      result.candidates.push(candidate);
      fs.writeFileSync(
        path.join(candidatesDir, `${tweet.id}.json`),
        JSON.stringify(candidate, null, 2),
        'utf8'
      );
    }

    fs.writeFileSync(seenFile, JSON.stringify(seen, null, 2), 'utf8');
    fs.writeFileSync(outboxFile, JSON.stringify({
      generated_at: result.fetched_at,
      candidates: result.candidates
    }, null, 2), 'utf8');

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
