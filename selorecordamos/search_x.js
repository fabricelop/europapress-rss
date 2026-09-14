const fs = require('fs');
const { chromium } = require('playwright');

(async () => {
  const query = '"recordadme" OR "que alguien me recuerde"';
  const url = `https://x.com/search?q=${encodeURIComponent(query)}&src=typed_query&f=live`;
  const outDir = 'selorecordamos/debug';
  fs.mkdirSync(outDir, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    locale: 'es-ES',
    timezoneId: 'Europe/Madrid',
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  });
  const page = await context.newPage();
  const result = {
    query,
    search_url: url,
    fetched_at: new Date().toISOString(),
    final_url: null,
    title: null,
    tweets: [],
    status: 'unknown',
    note: null
  };

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(8000);
    result.final_url = page.url();
    result.title = await page.title();

    const loginVisible = await page.locator('text=Inicia sesión').first().isVisible().catch(() => false);
    const tweetArticles = page.locator('article[data-testid="tweet"]');
    const count = await tweetArticles.count();

    for (let i = 0; i < Math.min(count, 20); i++) {
      const article = tweetArticles.nth(i);
      const text = await article.locator('[data-testid="tweetText"]').innerText().catch(() => '');
      const links = await article.locator('a[href*="/status/"]').evaluateAll(els => els.map(a => a.getAttribute('href')).filter(Boolean)).catch(() => []);
      const statusPath = links.find(h => /^\/[^/]+\/status\/\d+/.test(h));
      if (!text || !statusPath) continue;
      const m = statusPath.match(/^\/([^/]+)\/status\/(\d+)/);
      if (!m) continue;
      const [, user, id] = m;
      result.tweets.push({ id, user: `@${user}`, text, url: `https://x.com/${user}/status/${id}` });
    }

    if (result.tweets.length) {
      result.status = 'ok';
      result.note = `Extraídos ${result.tweets.length} tuits sin autenticación.`;
    } else if (loginVisible || /login|i\/flow\/login/.test(result.final_url || '')) {
      result.status = 'auth_required';
      result.note = 'X exige sesión autenticada para mostrar los resultados de búsqueda.';
    } else {
      result.status = 'no_results';
      result.note = 'La página cargó, pero no se encontraron artículos de tuit. Puede ser bloqueo, challenge o cambio de interfaz.';
    }

    await page.screenshot({ path: `${outDir}/search.png`, fullPage: true });
    fs.writeFileSync(`${outDir}/page.html`, await page.content());
  } catch (e) {
    result.status = 'error';
    result.note = String(e && e.stack ? e.stack : e);
  } finally {
    fs.writeFileSync(`${outDir}/results.json`, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result, null, 2));
    await browser.close();
  }
})();
