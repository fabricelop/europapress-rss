// TT Chrome 9223 tab audit (read-only). Node 20+; no external dependencies.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const base='http://127.0.0.1:9223';
const work='C:\\TTiTTulares';
const outputDir=path.join(process.env.LOCALAPPDATA || os.tmpdir(),'TT_Recuperacion');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));

function pinned(name){
  const file=path.join(work,name);
  try{
    const j=JSON.parse(fs.readFileSync(file,'utf8'));
    return String(j.target_id || '');
  }catch{return ''}
}
const pinT=pinned('ttittulares-image-tab.json');
const pinR=pinned('ttendencias-image-tab.json');

function cdpInspect(target){
  return new Promise(resolve=>{
    if(!target.webSocketDebuggerUrl || typeof WebSocket!=='function')return resolve({inspect_error:'CDP WebSocket unavailable'});
    let ws=null,finished=false;
    const timer=setTimeout(()=>finish({inspect_error:'CDP timeout'}),4500);
    function finish(result){
      if(finished)return;
      finished=true;clearTimeout(timer);
      try{if(ws)ws.close()}catch{}
      resolve(result);
    }
    const expression=`(()=>{const buttons=[...document.querySelectorAll('button')];const stop=buttons.some(b=>{const t=String(b.getAttribute('aria-label')||b.getAttribute('title')||'');return /^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(t)}) || !!document.querySelector('button[data-testid="stop-button"]');const main=document.querySelector('main');const recent=String((main&&main.innerText)||'').slice(-6000);const textBusy=/(creating image|generating image|generando imagen|creando imagen|generando la imagen)/i.test(recent);return {ready:document.readyState,navAgeMinutes:Math.round((Date.now()-performance.timeOrigin)/60000),generating:stop||textBusy,stopButton:stop,textBusy,hasComposer:!!document.querySelector('#prompt-textarea,[data-testid="prompt-textarea"],[contenteditable="true"][role="textbox"]'),visibility:document.visibilityState,route:location.pathname.startsWith('/c/')?'conversation':(location.pathname==='/'?'home':'other')}})()`;
    try{
      ws=new WebSocket(target.webSocketDebuggerUrl);
      ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:901,method:'Runtime.evaluate',params:{expression,returnByValue:true,awaitPromise:false}}))}catch(e){finish({inspect_error:String(e.message||e)})}},{once:true});
      ws.addEventListener('message',e=>{
        try{
          const d=JSON.parse(String(e.data));
          if(d.id!==901)return;
          if(d.error)return finish({inspect_error:String(d.error.message||'CDP error')});
          const val=d.result&&d.result.result&&d.result.result.value;
          if(!val)return finish({inspect_error:'CDP returned no value'});
          finish(val);
        }catch(e){finish({inspect_error:String(e.message||e)})}
      });
      ws.addEventListener('error',()=>finish({inspect_error:'CDP socket error'}),{once:true});
      ws.addEventListener('close',()=>finish({inspect_error:'CDP socket closed'}),{once:true});
    }catch(e){finish({inspect_error:String(e.message||e)})}
  })
}
async function parallel(items,limit,fn){
  let index=0;const result=new Array(items.length);
  await Promise.all(Array.from({length:Math.min(limit,items.length)},async()=>{
    while(index<items.length){const i=index++;result[i]=await fn(items[i],i)}
  }));
  return result
}
(async()=>{
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),8000);
  let targets=[];
  try{
    const response=await fetch(base+'/json/list',{cache:'no-store',signal:controller.signal});
    if(!response.ok)throw Error('CDP HTTP '+response.status);
    targets=await response.json();
    if(!Array.isArray(targets))throw Error('Unexpected CDP response');
  }finally{clearTimeout(timer)}

  const pages=targets.filter(t=>t.type==='page');
  const chat=pages.filter(t=>{try{return new URL(t.url).hostname==='chatgpt.com'}catch{return false}});
  const results=await parallel(chat,6,async t=>{
    const inspect=await cdpInspect(t);
    return {id:String(t.id||''),url:String(t.url||''),title:String(t.title||''),pinnedTT:String(t.id)===pinT,pinnedTR:String(t.id)===pinR,...inspect}
  });
  const nGen=results.filter(r=>r.generating).length;
  const nUnknown=results.filter(r=>r.inspect_error).length;
  const nOld=results.filter(r=>!r.inspect_error&&!r.generating&&r.ready==='complete'&&r.navAgeMinutes>=60&&!r.pinnedTT&&!r.pinnedTR).length;
  const nRecent=results.filter(r=>!r.inspect_error&&!r.generating&&Number(r.navAgeMinutes)<60).length;
  fs.mkdirSync(outputDir,{recursive:true});
  const ts=new Date().toISOString().replace(/[:.]/g,'-');
  const reportPath=path.join(outputDir,'chrome9223-tabs-'+ts+'.json');
  const report={timestamp:new Date().toISOString(),counts:{cdp_targets:targets.length,pages:pages.length,chatgpt_pages:chat.length,generating:nGen,unknown:nUnknown,old_loaded_unpinned:nOld,recent:nRecent},pinned:{ttittulares:{id:pinT,active:results.some(r=>r.pinnedTT)},ttendencias:{id:pinR,active:results.some(r=>r.pinnedTR)}},pages:results};
  fs.writeFileSync(reportPath,JSON.stringify(report,null,2),'utf8');
  console.log('\n=== DIAGNOSTICO CHROME 9223 (SIN CERRAR NADA) ===');
  console.log('Targets CDP totales:',targets.length);
  console.log('Paginas totales:',pages.length);
  console.log('Pestanas ChatGPT:',chat.length);
  console.log('Pestana fija TTit:',report.pinned.ttittulares.active?'VALIDA':'NO ENCONTRADA');
  console.log('Pestana fija TTendencias:',report.pinned.ttendencias.active?'VALIDA':'NO ENCONTRADA');
  console.log('Con indicios de generacion:',nGen);
  console.log('Estado no verificable (protegidas):',nUnknown);
  console.log('Cargadas hace >=60 min, no fijas y sin generacion detectada:',nOld);
  console.log('Otras recientes sin generacion detectada:',nRecent);
  console.log('\nMuestra de pestañas (sin URLs completas ni mensajes):');
  const sorted=results.slice().sort((a,b)=>Number(b.navAgeMinutes||0)-Number(a.navAgeMinutes||0));
  for(const r of sorted.slice(0,15)){
    console.log(String(r.id).slice(0,12).padEnd(13),String(r.navAgeMinutes??'?').padStart(5)+'m',
      (r.pinnedTT?'TTIT':r.pinnedTR?'TREN':r.generating?'GENERANDO':r.inspect_error?'DESCONOCIDA':'SIN INDICIOS DE GENERACION'),
      String(r.route||''));
  }
  console.log('Informe completo guardado en:',reportPath);
  console.log('Ninguna pestaña o proceso ha sido cerrado.');
})().catch(e=>{console.error('AUDIT ERROR:',String(e.stack||e));process.exitCode=1});
