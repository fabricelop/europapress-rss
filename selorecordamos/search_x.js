const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

(async () => {

  // Evitar instancias superpuestas de Playwright.
  const singleInstanceLock = path.join(__dirname, 'runtime', path.basename(__filename) + '.lock');
  fs.mkdirSync(path.dirname(singleInstanceLock), { recursive: true });
  function processAlive(pid) {
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try { process.kill(pid, 0); return true; }
    catch (e) { return e && e.code === 'EPERM'; }
  }
  function acquireLock() {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const fd = fs.openSync(singleInstanceLock, 'wx');
        try { fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, started: new Date().toISOString() })); }
        finally { fs.closeSync(fd); }
        process.on('exit', () => {
          try {
            const current = JSON.parse(fs.readFileSync(singleInstanceLock, 'utf8'));
            if (current.pid === process.pid) fs.unlinkSync(singleInstanceLock);
          } catch (_) {}
        });
        return true;
      } catch (e) {
        if (e.code !== 'EEXIST') throw e;
        let owner = null;
        try { owner = JSON.parse(fs.readFileSync(singleInstanceLock, 'utf8')); } catch (_) {}
        if (owner && processAlive(owner.pid)) {
          console.log('SR_ALREADY_RUNNING ' + path.basename(__filename) + ' pid=' + owner.pid);
          return false;
        }
        // Un proceso terminado puede dejar un candado obsoleto.
        try { fs.unlinkSync(singleInstanceLock); } catch (_) {}
      }
    }
    return false;
  }
  if (!acquireLock()) return;

  const query = '"recordadme" OR "que alguien me recuerde" OR "alguien que me recuerde" OR "alguien me recuerde" OR "que me recuerden" OR "@SeLoRecordamos"';
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
  const chromePath = process.env.SR_CHROME_PATH || (process.platform === 'win32' ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' : '');
  // En el PC Windows se mantiene el navegador visible por defecto. En GitHub Actions/CI
  // no hay servidor gráfico, así que Playwright debe arrancar automáticamente en headless.
  // SR_HEADLESS=1/0 sigue permitiendo forzar explícitamente el comportamiento.
  const headless = process.env.SR_HEADLESS === '1' || (process.env.SR_HEADLESS !== '0' && (process.env.CI === 'true' || process.platform !== 'win32'));
  const backfillSinceRaw = String(process.env.SR_BACKFILL_SINCE || '').trim();
  const parsedSince = backfillSinceRaw ? Date.parse(backfillSinceRaw) : NaN;
  const backfillDays = Math.max(0, Number(process.env.SR_BACKFILL_DAYS || '0') || 0);
  const backfillCutoff = Number.isFinite(parsedSince) ? parsedSince : (backfillDays > 0 ? Date.now() - backfillDays * 86400000 : null);
  const isBackfill = backfillCutoff !== null;

  let seen = {};
  try { seen = JSON.parse(fs.readFileSync(seenFile, 'utf8')); } catch (_) { seen = {}; }

  const readJson = (file, fallback) => {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (_) { return fallback; }
  };

  const normalizeText = (text) => String(text || '').toLocaleLowerCase('es-ES').replace(/\s+/g, ' ').trim();
  const rejectReason = (text) => {
    const normalized = normalizeText(text);
    if (normalized.includes('me recuerden por')) return 'excluded_phrase_me_recuerden_por';
    if (normalized.includes('me recuerden a')) return 'excluded_phrase_me_recuerden_a';
    if (normalized.includes('me recuerde con')) return 'excluded_phrase_me_recuerde_con';
    if (normalized.includes('los que me recuerden')) return 'excluded_phrase_los_que_me_recuerden';
    return null;
  };

  const telegramSentFile = path.join(stateDir, 'telegram-sent.json');
  const existingOutbox = readJson(outboxFile, { candidates: [] });
  const telegramSent = readJson(telegramSentFile, {});
  const pendingBeforeSearch = new Map();

  for (const c of existingOutbox.candidates || []) {
    const id = String(c && c.id || '');
    if (id && !telegramSent[id] && !rejectReason(c && c.text)) pendingBeforeSearch.set(id, c);
  }

  // Recuperación adicional: si una ejecución anterior encontró el candidato pero
  // Git/Telegram fallaron después, candidates/*.json conserva una copia local.
  try {
    for (const file of fs.readdirSync(candidatesDir).filter(x => x.endsWith('.json'))) {
      const c = readJson(path.join(candidatesDir, file), null);
      const id = String(c && c.id || '');
      if (id && !telegramSent[id] && !rejectReason(c && c.text)) pendingBeforeSearch.set(id, c);
    }
  } catch (_) {}
  const launchOptions = { headless };
  if (chromePath && fs.existsSync(chromePath)) launchOptions.executablePath = chromePath;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({ locale:'es-ES', timezoneId:'Europe/Madrid', userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36' });
  if (authToken && ct0) await context.addCookies([{name:'auth_token',value:authToken,domain:'.x.com',path:'/',httpOnly:true,secure:true,sameSite:'None'},{name:'ct0',value:ct0,domain:'.x.com',path:'/',httpOnly:false,secure:true,sameSite:'Lax'}]);
  const page = await context.newPage();
  const result={query,search_url:url,fetched_at:new Date().toISOString(),authenticated_cookie_pair_present:Boolean(authToken&&ct0),mode:isBackfill?`backfill_since_${new Date(backfillCutoff).toISOString()}`:'incremental',final_url:null,title:null,extracted:0,scroll_rounds:0,already_seen:0,rejected:[],candidates:[],status:'unknown',note:null};
  async function openSearchWithRetry() {
    // X frequently hangs while firing background network requests. A visible
    // page can still be usable even if the navigation promise times out.
    const attempts = [];
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        await page.goto(url, { waitUntil: 'commit', timeout: 25000 });
        await page.locator('article[data-testid="tweet"], [data-testid="primaryColumn"], main')
          .first().waitFor({ state: 'attached', timeout: 20000 });
        return { ok: true, attempt };
      } catch (error) {
        attempts.push(String(error?.message || error).slice(0, 240));
        const current = page.url();
        const visible = await page.locator('article[data-testid="tweet"]').count().catch(() => 0);
        // On a partial-but-usable load, consume the tweets instead of
        // losing the whole search run to domcontentloaded timeout.
        if (visible > 0 && current.startsWith('https://x.com/')) {
          return { ok: true, attempt, recovered_partial: true };
        }
        if (attempt < 2) {
          await page.waitForTimeout(1500 * attempt);
        }
      }
    }
    throw new Error('X_SEARCH_NAVIGATION_FAILED after 2 attempts: ' + attempts.join(' / '));
  }

  const readVisibleTweets=async()=>{const articles=page.locator('article[data-testid="tweet"]');const count=await articles.count();const tweets=[];for(let i=0;i<count;i++){const article=articles.nth(i);const text=await article.locator('[data-testid="tweetText"]').innerText().catch(()=>'');const timeEl=article.locator('time').first();const datetime=await timeEl.getAttribute('datetime').catch(()=>null);const timeHref=await timeEl.locator('xpath=..').getAttribute('href').catch(()=>null);const links=await article.locator('a[href*="/status/"]').evaluateAll(els=>els.map(a=>a.getAttribute('href')).filter(Boolean)).catch(()=>[]);const statusPath=(timeHref&&/^\/[^/]+\/status\/\d+/.test(timeHref))?timeHref:links.find(h=>/^\/[^/]+\/status\/\d+/.test(h));if(!text||!statusPath)continue;const m=statusPath.match(/^\/([^/]+)\/status\/(\d+)/);if(!m)continue;const[,user,id]=m;tweets.push({id,user:`@${user}`,text,datetime,url:`https://x.com/${user}/status/${id}`});}return tweets;};
  try{
    result.navigation=await openSearchWithRetry();await page.waitForTimeout(4000);result.final_url=page.url();result.title=await page.title();const loginVisible=await page.locator('text=Inicia sesión').first().isVisible().catch(()=>false);const extractedMap=new Map();let stableRounds=0,seenBoundaryRounds=0;const incrementalLookbackMs=24*60*60*1000;const incrementalCutoff=Date.now()-incrementalLookbackMs;const maxScrollRounds=isBackfill?200:60;
    for(let round=0;round<maxScrollRounds;round++){const visible=await readVisibleTweets();const before=extractedMap.size;for(const tweet of visible)extractedMap.set(tweet.id,tweet);const added=extractedMap.size-before;result.scroll_rounds=round+1;if(added===0)stableRounds++;else stableRounds=0;if(isBackfill){const dated=visible.map(t=>t.datetime?Date.parse(t.datetime):NaN).filter(Number.isFinite);if(dated.length&&Math.min(...dated)<=backfillCutoff)break;if(stableRounds>=6)break;}else{const dated=visible.map(t=>t.datetime?Date.parse(t.datetime):NaN).filter(Number.isFinite);const oldest=dated.length?Math.min(...dated):null;const visibleIds=visible.map(t=>t.id);const reachedSeenBoundary=visibleIds.some(id=>Boolean(seen[id]));if(reachedSeenBoundary)seenBoundaryRounds++;else seenBoundaryRounds=0;if(oldest!==null&&oldest<=incrementalCutoff&&seenBoundaryRounds>=2)break;if(stableRounds>=6)break;}await page.evaluate(()=>window.scrollTo(0,document.body.scrollHeight));await page.waitForTimeout(1400);}
    let extracted=Array.from(extractedMap.values());if(isBackfill)extracted=extracted.filter(t=>!t.datetime||Date.parse(t.datetime)>=backfillCutoff);result.extracted=extracted.length;
    for(const tweet of extracted){if(seen[tweet.id]){result.already_seen++;continue;}const reason=rejectReason(tweet.text);seen[tweet.id]={first_seen_at:result.fetched_at,url:tweet.url,rejected:Boolean(reason),datetime:tweet.datetime||null};if(reason){result.rejected.push({...tweet,reason});continue;}const candidate={...tweet,first_seen_at:result.fetched_at,status:'pending'};result.candidates.push(candidate);fs.writeFileSync(path.join(candidatesDir,`${tweet.id}.json`),JSON.stringify(candidate,null,2),'utf8');}
    fs.writeFileSync(seenFile,JSON.stringify(seen,null,2),'utf8');
    for (const c of result.candidates) pendingBeforeSearch.set(String(c.id), c);
    fs.writeFileSync(outboxFile,JSON.stringify({generated_at:result.fetched_at,candidates:[...pendingBeforeSearch.values()].slice(-200)},null,2),'utf8');
    if(result.candidates.length){result.status='ok';result.note=`${result.candidates.length} candidatos nuevos de ${result.extracted} tuits extraídos.`;}else if(!authToken||!ct0){result.status='missing_secrets';result.note='Faltan X_AUTH_TOKEN y/o X_CT0 en las variables de entorno.';}else if(loginVisible||/login|i\/flow\/login/.test(result.final_url||'')){result.status='auth_required';result.note='Las cookies no han autenticado la sesión de X o han caducado.';}else{result.status='no_new_candidates';result.note=`Sin candidatos nuevos. Extraídos: ${result.extracted}; ya vistos: ${result.already_seen}; descartados: ${result.rejected.length}.`;}
    await page.screenshot({path:path.join(outDir,'search.png'),fullPage:true});fs.writeFileSync(path.join(outDir,'page.html'),await page.content(),'utf8');
  }catch(e){
    result.status='error';result.note=String(e&&e.stack?e.stack:e);
    // Never silently lose candidates if X is temporarily unreachable.
    // Keep any pre-existing unsent candidates available to the Telegram listener.
    if (pendingBeforeSearch.size) {
      const recovered={generated_at:new Date().toISOString(),
        candidates:[...pendingBeforeSearch.values()].slice(-200)};
      fs.writeFileSync(outboxFile,JSON.stringify(recovered,null,2),'utf8');
      result.pending_preserved=recovered.candidates.length;
    }
  }finally{fs.writeFileSync(path.join(outDir,'results.json'),JSON.stringify(result,null,2),'utf8');console.log(JSON.stringify(result,null,2));await browser.close();if(['error','auth_required','missing_secrets'].includes(result.status))process.exitCode=1;}
})();
