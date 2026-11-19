import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {chromium} from 'playwright';

// Only fictitious rows, in memory. No real trend is marked, reset or republished.
const entry='2026-11-19T18:16:00Z';
const item=(id,rank,name,capturedAt,movement='entry')=>({
  trend_id:'trv2-'+id.repeat(24),rank,name,revision:1,
  entered_top30_at:entry,captured_at:capturedAt,movement,
  status:'explicada',explanation:'Este es un texto de prueba para comprobar el aspecto de la fecha.',
  image_suppressed:true,image_available:false,previous_rank:null
});
const feed={project:'ttactualidad-v2',country:'ES',count:3,captured_at:'2026-11-19T20:20:00Z',items:[
  item('a',1,'BUGS','2026-11-18T21:40:00Z'),
  item('b',2,'Tema antiguo','2026-11-17T17:00:00Z','reentry'),
  item('c',3,'Tema vigente','2026-11-19T19:00:00Z')
]};
const dist=path.resolve('dist');
const shots=path.resolve(process.env.RUNNER_TEMP||'.','ttv2-trend-dates-qa');
await fs.mkdir(shots,{recursive:true});
let mutations=0;
const server=http.createServer(async(req,res)=>{
  const pathname=new URL(req.url,'http://localhost').pathname;
  const json=payload=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify(payload))};
  if(req.method!=='GET'&&pathname.startsWith('/api/')){mutations++;return json({ok:false})}
  if(pathname==='/api/state/web-top30.json')return json(feed);
  if(pathname==='/api/marks')return json({marks:{}});
  if(['/api/re-explain','/api/incident-rex','/api/incident-retry'].includes(pathname))return json({requests:[]});
  if(pathname==='/api/publication-count')return json({count:0,events:[]});
  if(pathname.startsWith('/api/'))return json({});
  const file=path.join(dist,pathname==='/'?'index.html':pathname);
  try{const content=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(content)}
  catch{res.statusCode=404;res.end()}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
try{
  for(const width of [1280,375]){
    const page=await browser.newPage({viewport:{width,height:850}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.route('https://ttactualidad.rainyraven22.chatgpt.site/api/manual-v2-image/catalog',route=>route.fulfill({json:{schema_version:1,images:[]}}));
    await page.goto('http://127.0.0.1:'+server.address().port+'/',{waitUntil:'domcontentloaded'});
    await page.locator('details.trend').first().waitFor({timeout:15000});
    const cards=page.locator('details.trend');
    if(await cards.count()!==3)throw Error('TREND_QA_NOT_THREE_CARDS');
    const labels=await page.locator('.explanation-age').allTextContents();
    if(labels.join(',')!=='REVISAR,ANTIGUA,VIGENTE')throw Error('TREND_QA_BAD_FRESHNESS '+labels);
    const bugs=cards.nth(0);
    if(!/En el Top 30 desde: 19\/11.*19:16/.test(await bugs.locator('.entered-top30').textContent()))throw Error('TREND_QA_ENTRY_LABEL');
    if(!/Explicada el: 18\/11.*22:40/.test(await bugs.locator('.explained-at').textContent()))throw Error('TREND_QA_EDITORIAL_LABEL');
    if(!/Regresó al Top 30 el:/.test(await cards.nth(1).locator('.entered-top30').textContent()))throw Error('TREND_QA_RETURN_LABEL');
    for(const [n,tone] of ['age-review','age-old','age-current'].entries()){
      if(!await cards.nth(n).locator('.explanation-age.'+tone).isVisible())throw Error('TREND_QA_BAD_COLOR_'+tone);
    }
    if(await page.locator('.red-toggle').count()!==3)throw Error('TREND_QA_R_MISSING');
    if(await page.locator('.red-toggle[aria-pressed="true"]').count())throw Error('TREND_QA_R_NOT_PRIVATE');
    await bugs.locator('summary').click();
    if(!await bugs.getByRole('button',{name:/Resetear y elaborar de nuevo BUGS/}).count())throw Error('TREND_QA_RE_MISSING');
    await page.screenshot({path:path.join(shots,'trend-dates-'+width+'.png'),fullPage:true});
    if(errors.length)throw Error('TREND_QA_PAGE_ERROR '+errors.join('; '));
    await page.close();
  }
  if(mutations!==0)throw Error('TREND_QA_UNEXPECTED_WRITE '+mutations);
  console.log('TT_V2_TREND_DATES_DESKTOP_MOBILE=OK');
}finally{await browser.close();await new Promise(resolve=>server.close(resolve))}
