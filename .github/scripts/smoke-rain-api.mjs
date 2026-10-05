import assert from 'node:assert/strict';
import forecast from '../../vercel-webhook/api/rain-forecast.js';
import nowcast from '../../vercel-webhook/api/rain-nowcast.js';
import geocode from '../../vercel-webhook/api/rain-geocode.js';

async function invoke(handler, query={}){
  let status=200,body='',headers={};
  const req={method:'GET',query};
  let resolveEnd;
  const ended=new Promise(r=>{resolveEnd=r});
  const res={
    set statusCode(v){status=v},get statusCode(){return status},
    setHeader(k,v){headers[String(k).toLowerCase()]=v},
    end(v=''){body+=v;resolveEnd()}
  };
  await handler(req,res);
  await ended;
  let json;try{json=JSON.parse(body)}catch{throw new Error('Respuesta no JSON: '+body.slice(0,300))}
  return{status,headers,json};
}

const location={lat:'40.4168',lon:'-3.7038'};
const g=await invoke(geocode,{q:'Madrid'});
assert.equal(g.status,200);
assert.ok(Array.isArray(g.json.results)&&g.json.results.length>0,'geocode sin resultados');
console.log('GEOCODE_OK',g.json.results[0].name);

const f=await invoke(forecast,location);
assert.equal(f.status,200,'forecast HTTP '+f.status+' '+JSON.stringify(f.json));
assert.ok(Array.isArray(f.json.timeline),'timeline ausente');
assert.ok(f.json.sources?.health?.available>0,'ninguna fuente forecast disponible');
console.log('FORECAST_OK',{points:f.json.timeline.length,health:f.json.sources.health,next:f.json.nextEvent?.start||null});

const n=await invoke(nowcast,location);
assert.equal(n.status,200,'nowcast HTTP '+n.status+' '+JSON.stringify(n.json));
assert.ok(['ok','motion_uncertain','insufficient_frames','insufficient_radar_data'].includes(n.json.status),'estado nowcast inesperado '+n.json.status);
assert.ok(n.json.source?.name==='RainViewer'||n.json.status.startsWith('insufficient'),'atribución radar ausente');
console.log('NOWCAST_OK',{status:n.json.status,confidence:n.json.confidence,event:n.json.event?.start||null,diagnostics:n.json.diagnostics||null});
