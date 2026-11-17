import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {projectNews,pageNews,NEWS_SOURCE} from '../src/news.js';
import {chromium} from 'playwright';
const [index,queue]=await Promise.all(['news-index.json','editorial-queue.json'].map(async name=>{const r=await fetch(NEWS_SOURCE+name);if(!r.ok)throw Error('NEWS_SOURCE_UNAVAILABLE');return r.json();}));
let view=projectNews(index,queue);
console.log('REAL_NEWS_PROJECTION',JSON.stringify({counts:view.counts,observed_at:view.observed_at}));
// UI QA needs one pending card even when the real Windows consumer has just
// drained that queue. Add a synthetic *in-memory* test row; never persist it.
if(!view.items.some(x=>x.group==='pending')){
 const existing=view.items.find(x=>x.group==='ready')||view.items.find(x=>x.group==='incident')||view.items[0];
 if(!existing)throw Error('NEWS_BROWSER_QA_NO_BASELINE_NEWS');
 view={...view,items:[...view.items,{...existing,group:'pending',status_label:'Pendiente de elaboración'}],
  counts:{...view.counts,pending:1}};
}
const root=path.resolve('dist');
const shots=path.resolve(process.env.RUNNER_TEMP||'.','ttv2-news-qa');await fs.mkdir(shots,{recursive:true});
let fail=false,demoReady=false,archived=false;
const example=view.items.find(x=>x.group==='pending');
const demoTweet="Una explicación breve de prueba, con hechos contrastados y preparada para un tuit. #Prueba #Noticias";
const demoRecord={event_id:example.event_id,revision:example.revision,tweet_text:demoTweet,x_character_count:demoTweet.length,title:example.title,factual_summary:'Hecho contrastado de prueba.'};
const readyView={...view,items:[{...example,group:'ready',status_label:'Elaborada',image_incident_available:true}],counts:{...view.counts,ready:1}};
const demoIncident={project:'ttittulares-v2',target_id:example.event_id,revision:example.revision,available:true,
 incident:{code:'NEWS_IMAGE_ORIGINAL_MISSING',detail:'No se ha podido recuperar el original de la imagen.',at:new Date().toISOString()}};
const requests=[];
const server=http.createServer(async(req,res)=>{
 const u=new URL(req.url,'http://localhost');requests.push(u.pathname);
 if(u.pathname==='/api/news'){
  res.setHeader('Content-Type','application/json');
  if(fail){res.statusCode=503;res.end('{}');return;}
  res.end(JSON.stringify(pageNews(demoReady?(archived?{...readyView,items:readyView.items.map(x=>({...x,group:'archived',status_label:'Archivada'})),counts:{...readyView.counts,ready:0,archived:1}}:readyView):view,u.searchParams)));return;
 }
 if(u.pathname==='/api/news-actions'){
  let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
  if(body.action==='archive'||body.action==='publish')archived=true;
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:true,publication_sent:false}));return;
 }
 if(u.pathname.startsWith('/api/news/')&&demoReady){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(demoRecord));return;}
 if(u.pathname==='/api/image-incidents'&&demoReady){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(demoIncident));return;}
 if(u.pathname==='/api/news-publication-count'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({count:3,events:[]}));return;}
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
 await page.waitForFunction(()=>document.querySelector('.news-filter[aria-pressed="true"]')?.textContent.startsWith('Elab.'));
 if(await page.locator('.news-card').count()!==Math.min(view.counts.ready,40))throw Error('Default must show Elaboradas');
 if(await page.locator('.news-eyebrow,#news-time').count())throw Error('Intro text should be removed');
 await page.screenshot({path:path.join(shots,'news-default.png'),fullPage:false});
 await page.getByRole('button',{name:'Pendientes · '+view.counts.pending,exact:true}).click();
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 await page.waitForFunction(()=>document.getElementById('publication-summary')?.textContent==='PUB · 3 / 24 h');
 if(!(await page.locator('#publication-summary').isVisible()))throw Error('News PUB counter hidden');
 if(requests.includes('/api/publication-count'))throw Error('Trend PU count requested on news view');
 if(requests.includes('/api/state/web-top30.json'))throw Error('News starts hidden trends requests');
 await page.screenshot({path:path.join(shots,'news-desktop.png'),fullPage:false});
 await page.getByRole('button',{name:'Detectadas · '+view.counts.detected,exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.news-card').length===40);
 await page.getByRole('button',{name:'Siguiente →',exact:true}).click();
 await page.waitForFunction(()=>document.getElementById('news-page').textContent.includes('Página 2'));
 if(view.counts.incident){
  await page.getByRole('button',{name:'Incidencias · '+view.counts.incident,exact:true}).click();
  await page.locator('.news-card summary').first().click();
  if(await page.getByRole('button',{name:'↻ Reintentar',exact:true}).count()!==1||
     await page.getByRole('button',{name:'Suprimir',exact:true}).count()!==1)
   throw Error('INC manual retry and suppression buttons missing');
 }
 await page.getByRole('button',{name:'Pendientes · '+view.counts.pending,exact:true}).click();
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 await page.locator('#news-search').fill(view.items.find(x=>x.group==='pending').title.slice(0,22));
 await page.waitForFunction(()=>document.getElementById('news-count').textContent.includes('coincidencias'));
 if(await page.locator('.news-card').count()<1)throw Error('Search lost matching source title');
 await page.locator('#news-search').fill('');
 await page.waitForFunction(()=>!document.getElementById('news-count').textContent.includes('coincidencias'));
 await page.waitForFunction(n=>document.querySelectorAll('.news-card').length===n,Math.min(view.counts.pending,40));
 fail=true;await page.locator('#refresh').click();
 await page.waitForFunction(()=>!document.getElementById('news-error').hidden);
 if(await page.locator('.news-card').count()!==Math.min(view.counts.pending,40))throw Error('Failed refresh destroyed last known list');
 fail=false;await page.locator('#refresh').click();await page.waitForFunction(()=>document.getElementById('news-error').hidden);
 await page.setViewportSize({width:320,height:844});
 const row=await page.locator('.news-filter').evaluateAll(nodes=>nodes.map(n=>({top:n.getBoundingClientRect().top,right:n.getBoundingClientRect().right})));
 if(new Set(row.map(x=>Math.round(x.top))).size!==1||Math.max(...row.map(x=>x.right))>320)throw Error('Filters must fit one line at 320px');
 await page.setViewportSize({width:390,height:844});
 await page.locator('.news-card summary').first().click();
 await page.screenshot({path:path.join(shots,'news-mobile.png'),fullPage:false});
 if(await page.evaluate(()=>document.body.scrollWidth>innerWidth))throw Error('Mobile horizontal overflow');
 demoReady=true;await page.getByRole('button',{name:'Elaboradas · '+view.counts.ready,exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.news-card').length===1);
 await page.locator('.news-card summary').first().click();
 await page.waitForFunction(text=>document.querySelector('.news-tweet')?.textContent===text,demoTweet);
 if(!(await page.locator('.news-tweet-count').textContent()).includes('/ 280'))throw Error('Tweet counter missing');
 if(requests.includes('/api/image-incidents'))throw Error('Image incident was fetched before clicking I');
 await page.getByRole('button',{name:'Incidencia de imagen',exact:true}).click();
 await page.getByText(demoIncident.incident.detail,{exact:true}).waitFor({state:'visible'});
 if(await page.locator('.news-card[open]').count()!==1)throw Error('I did not open the exact card');
 await page.screenshot({path:path.join(shots,'news-image-incident-mobile.png'),fullPage:false});
 await page.getByRole('button',{name:'Incidencia de imagen',exact:true}).click();
 await page.getByRole('button',{name:'Incidencia de imagen',exact:true}).click();
 if(requests.filter(p=>p==='/api/image-incidents').length!==1)throw Error('Incident detail did not reuse the exact cached revision');
 await page.setViewportSize({width:1280,height:1000});
 await page.screenshot({path:path.join(shots,'news-image-incident-desktop.png'),fullPage:false});
 for(const label of ['R · Rojo','RE','RE-X','P-X','PUB','Quitar','Copiar prompt IA','GPT IMA','Pegar IA']){
  if(await page.locator('.news-actions').getByText(label,{exact:true}).count()!==1)throw Error('Missing news action: '+label);
 }
 page.on('dialog',dialog=>dialog.accept());
 await page.getByRole('button',{name:'PUB',exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.news-card').length===0);
 await page.getByRole('button',{name:'Archivo · 1',exact:true}).click();
 await page.waitForFunction(()=>document.querySelectorAll('.news-card').length===1);
 await page.locator('.news-card summary').first().click();
 await page.waitForFunction(text=>document.querySelector('.news-body p')?.textContent===text,demoTweet);
 await page.screenshot({path:path.join(shots,'news-pub-archive.png'),fullPage:false});
 if(errors.length)throw Error(errors.join('; '));
 console.log('NEWS_BROWSER_QA=PASS; default Elaboradas/compact filters/short READY tweet/paging/search/error retention/mobile/image incident I lazy detail=OK');
}finally{await browser.close();server.close();}

