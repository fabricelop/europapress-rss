const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const { chromium } = require('playwright');

(async()=>{
  const baseDir=__dirname;
  const repoDir=path.join(baseDir,'..');
  const outputFile=path.join(baseDir,'published-replies.json');
  const authToken=process.env.X_AUTH_TOKEN||'';
  const ct0=process.env.X_CT0||'';
  const chromePath=process.env.SR_CHROME_PATH||(process.platform==='win32'?'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe':'');
  const sinceRaw=String(process.env.SR_PUBLISHED_SINCE||'2026-09-14T00:00:00+02:00').trim();
  const since=Date.parse(sinceRaw);
  if(!authToken||!ct0)throw new Error('Faltan X_AUTH_TOKEN/X_CT0.');
  if(!Number.isFinite(since))throw new Error('SR_PUBLISHED_SINCE no es una fecha valida.');
  const launch={headless:process.env.SR_HEADLESS==='1'};
  if(chromePath&&fs.existsSync(chromePath))launch.executablePath=chromePath;
  const browser=await chromium.launch(launch);
  const context=await browser.newContext({locale:'es-ES',timezoneId:'Europe/Madrid',userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'});
  await context.addCookies([{name:'auth_token',value:authToken,domain:'.x.com',path:'/',httpOnly:true,secure:true,sameSite:'None'},{name:'ct0',value:ct0,domain:'.x.com',path:'/',httpOnly:false,secure:true,sameSite:'Lax'}]);
  const page=await context.newPage();
  const url='https://x.com/SeLoRecordamos/with_replies';
  const found=new Map();let stable=0;
  try{
    await page.goto(url,{waitUntil:'domcontentloaded',timeout:60000});
    await page.waitForTimeout(7000);
    for(let round=0;round<120;round++){
      const articles=page.locator('article[data-testid="tweet"]');
      const count=await articles.count();
      const before=found.size;
      let oldest=Date.now();
      for(let i=0;i<count;i++){
        const a=articles.nth(i);
        const links=await a.locator('a[href*="/status/"]').evaluateAll(els=>els.map(e=>e.getAttribute('href')).filter(Boolean)).catch(()=>[]);
        const ownPath=links.find(h=>/^\/SeLoRecordamos\/status\/\d+/i.test(String(h||'')));
        if(!ownPath)continue;
        const m=String(ownPath).match(/^\/SeLoRecordamos\/status\/(\d+)/i);
        if(!m)continue;
        const id=m[1];
        const text=await a.locator('[data-testid="tweetText"]').first().innerText().catch(()=>'');
        if(!text)continue;
        const timeEl=a.locator(`a[href="${ownPath}"] time`).first();
        let datetime=await timeEl.getAttribute('datetime').catch(()=>null);
        if(!datetime)datetime=await a.locator('time').first().getAttribute('datetime').catch(()=>null);
        const ts=datetime?Date.parse(datetime):NaN;
        if(Number.isFinite(ts))oldest=Math.min(oldest,ts);
        const quoted=links.map(h=>{const q=String(h||'').match(/^\/([^/]+)\/status\/(\d+)/);return q?`https://x.com/${q[1]}/status/${q[2]}`:null;}).find(u=>u&&u.toLowerCase()!==`https://x.com/selorecordamos/status/${id}`.toLowerCase())||null;
        found.set(id,{id,datetime:datetime||null,text:text.trim(),url:`https://x.com/SeLoRecordamos/status/${id}`,quoted_url:quoted});
      }
      if(found.size===before)stable++;else stable=0;
      if(oldest<=since||stable>=6)break;
      await page.evaluate(()=>window.scrollTo(0,document.body.scrollHeight));
      await page.waitForTimeout(1600);
    }
  }finally{await browser.close();}
  const posts=Array.from(found.values()).filter(x=>!x.datetime||Date.parse(x.datetime)>=since).sort((a,b)=>Date.parse(a.datetime||0)-Date.parse(b.datetime||0));
  const existing=(()=>{try{return JSON.parse(fs.readFileSync(outputFile,'utf8'));}catch(_){return{posts:[]};}})();
  const merged=new Map((existing.posts||[]).map(x=>[String(x.id),x]));for(const p of posts)merged.set(String(p.id),p);
  const all=Array.from(merged.values()).sort((a,b)=>Date.parse(a.datetime||0)-Date.parse(b.datetime||0));
  fs.writeFileSync(outputFile,JSON.stringify({updated_at:new Date().toISOString(),posts:all},null,2)+'\n','utf8');
  console.log(JSON.stringify({since:new Date(since).toISOString(),source:url,found_now:posts.length,total_history:all.length,posts},null,2));
  if(process.env.SR_PUBLISHED_PUSH==='1'){
    cp.execFileSync('git',['add','selorecordamos/published-replies.json'],{cwd:repoDir,stdio:'inherit'});
    const d=cp.spawnSync('git',['diff','--cached','--quiet'],{cwd:repoDir});
    if(d.status!==0){
      cp.execFileSync('git',['commit','-m','Update SeLoRecordamos published history'],{cwd:repoDir,stdio:'inherit'});
      try{cp.execFileSync('git',['push','origin','main'],{cwd:repoDir,stdio:'inherit'});}catch(_){
        cp.execFileSync('git',['pull','--rebase','--autostash','origin','main'],{cwd:repoDir,stdio:'inherit'});
        cp.execFileSync('git',['push','origin','main'],{cwd:repoDir,stdio:'inherit'});
      }
    }
  }
})().catch(e=>{console.error(e.stack||e);process.exit(1);});
