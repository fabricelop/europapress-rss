import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {projectNews,pageNews,NEWS_SOURCE} from '../src/news.js';
import {chromium} from 'playwright';
const [index,queue]=await Promise.all(['news-index.json','editorial-queue.json'].map(async name=>{const r=await fetch(NEWS_SOURCE+name);if(!r.ok)throw Error('NEWS_SOURCE_UNAVAILABLE');return r.json();}));
const view=projectNews(index,queue);
console.log('REAL_NEWS_PROJECTION',JSON.stringify({counts:view.counts,observed_at:view.observed_at}));
const root=path.resolve('dist');
const shots=path.resolve(process.env.RUNNER_TEMP||'.','ttv2-news-qa');await fs.mkdir(shots,{recursive:true});
let fail=false;
const requests=[];
const server=http.createServer(async(req,res)=>{
 const u=new URL(req.url,'http://localhost');requests.push(u.pathname);
 if(u.pathname==='/api/news'){
  res.setHeader('Content-Type','application/json');
  if(fail){res.statusCode=503;res.end('{}');return;}
  res.end(JSON.stringify(pageNews(view,u.searchParams)));return;
 }
 if(u.pathname.startsWith('/api/')){res.setHeader('Content-Type','application/json');res.end('{}');return;}
 const file=path.join(root,u.pathname==='/'?'index.html':u.pathname);
 try{const content=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(content);}catch{res.statusCode=404;res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage({viewport:{width:1280,height:1000}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port+'/?view=noticias');
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 if(await page.locator('#publication-summary').isVisible())throw Error('PU shown on news view');
 if(requests.includes('/api/state/web-top30.json'))throw Error('News starts hidden trends requests');
 await page.screenshot({path:path.join(shots,'news-desktop.png'),fullPage:false});
 await page.getByRole('button',{name:'Detectadas · '+view.counts.detected,exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.news-card').length===40);
 await page.getByRole('button',{name:'Siguiente →',exact:true}).click();
 await page.waitForFunction(()=>document.getElementById('news-page').textContent.includes('Página 2'));
 await page.getByRole('button',{name:'Pendientes · '+view.counts.pending,exact:true}).click();
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 await page.locator('#news-search').fill(view.items.find(x=>x.group==='pending').title.slice(0,22));
 await page.waitForFunction(()=>document.getElementById('news-count').textContent.includes('encontradas'));
 if(await page.locator('.news-card').count()<1)throw Error('Search lost matching source title');
 await page.locator('#news-search').fill('');
 await page.waitForFunction(()=>!document.getElementById('news-count').textContent.includes('encontradas'));
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 fail=true;await page.locator('#refresh').click();
 await page.waitForFunction(()=>!document.getElementById('news-error').hidden);
 if(await page.locator('.news-card').count()!==Math.min(view.counts.pending,40))throw Error('Failed refresh destroyed last known list');
 fail=false;await page.locator('#refresh').click();await page.waitForFunction(()=>document.getElementById('news-error').hidden);
 await page.setViewportSize({width:390,height:844});
 await page.locator('.news-card summary').first().click();
 await page.screenshot({path:path.join(shots,'news-mobile.png'),fullPage:false});
 if(await page.evaluate(()=>document.body.scrollWidth>innerWidth))throw Error('Mobile horizontal overflow');
 if(errors.length)throw Error(errors.join('; '));
 console.log('NEWS_BROWSER_QA=PASS; paging/search/error retention/mobile/private controls=OK');
}finally{await browser.close();server.close();}

