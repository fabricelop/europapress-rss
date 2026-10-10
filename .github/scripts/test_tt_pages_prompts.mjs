import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('docs/gag.html','utf8');
const match=html.match(/<script>([\s\S]+?)<\/script>/i);
assert(match, 'Missing standalone GAG JavaScript');
const code=match[1];
new vm.Script(code,{filename:'gag.html'});
async function scenario(query,fixtures){
  const elements=new Map();
  const element=(id)=>{
    if(!elements.has(id))elements.set(id,{textContent:'',value:'',disabled:true,className:'',onclick:null,focus(){},select(){}});
    return elements.get(id);
  };
  const ctx={
    document:{getElementById:element,execCommand:()=>true},
    location:{search:query},
    URLSearchParams,URL,TextEncoder,TextDecoder,Uint8Array,
    navigator:{clipboard:{writeText:async()=>{}}},
    fetch:async(url)=>{
      const path=Object.keys(fixtures).find(p=>String(url).includes(p));
      return path?{ok:true,json:async()=>fixtures[path]}:{ok:false,json:async()=>({})};
    },
    console
  };
  vm.runInNewContext(code,ctx,{timeout:1000});
  for(let i=0;i<50&&!element('prompt').value;i++)await new Promise(r=>setTimeout(r,2));
  return element('prompt').value;
}
const newsBody='La noticia contiene hechos verificados completos y una frase irónica.\n\n🌶️ Remate de noticia exacto.';
const news=await scenario('?app=ttittulares&id=abcdef123456&rev=2',{
  'ttittulares/prepared.json':{items:[{event_id:'abcdef123456',revision:2,title:'Un gran titular',
    factual_summary:'Contexto factual complementario sin inventar.',tweet:{text:newsBody,remate:'🌶️ Remate de noticia exacto.'}}]},
  'telegram/editorial-processing.json':{items:[]}
});
assert(news.includes(newsBody),'News text was shortened');
assert(news.includes('🌶️ Remate de noticia exacto.'),'News remate missing');
assert(news.includes('Contexto factual complementario sin inventar.'),'News factual summary missing');
const trendText='TT#4 Bukaneros es tendencia porque se suspendió el partido del Rayo por protestas y aviones de papel.';
const trends=await scenario('?app=ttendencias&id=trends123&rev=3&name=Bukaneros',{
  'trends/telegram-manual-explained.json':{items:[{id:'trends123',revision:3,name:'Bukaneros',
    explanation:trendText,closer_text:'🌶️ La protesta llegó con aerodinámica de barrio.'}]},
  'trends/explained.json':{items:[{id:'trends123',revision:2,explanation:'Texto antiguo que NO debe aparecer.'}]},
  'trends/requests.json':{requests:[{id:'trends123',revision:3,name:'Bukaneros',rank:4}]}
});
assert(trends.includes(trendText),'Trend complete explanation missing');
assert(trends.includes('🌶️ La protesta llegó con aerodinámica de barrio.'),'Trend remate missing');
assert(!trends.includes('Texto antiguo que NO debe aparecer.'),'Old revision contaminated trend');
const old=await scenario('?app=ttendencias&id=trends123&rev=4&name=Bukaneros',{
  'trends/telegram-manual-explained.json':{items:[{id:'trends123',revision:3,name:'Bukaneros',
    explanation:'Explicación vieja que no debe usarse.'}]},
  'trends/explained.json':{items:[]},
  'trends/requests.json':{requests:[{id:'trends123',revision:4,name:'Bukaneros',status:'preparing'}]}
});
assert(old==='','Should never generate from stale revision or bare title');
console.log('TT_GAG_PAGES_EXACT_TEXT_TESTS_OK: news, trend and stale revision');
