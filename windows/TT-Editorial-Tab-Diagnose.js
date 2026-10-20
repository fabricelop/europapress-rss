'use strict';
// READ ONLY. Diagnoses tracked 9223 editorial tabs. Does not close or open tabs,
// create jobs, mutate queues, or touch images. No chat text is captured.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const BASE='http://127.0.0.1:9223',HOME='C:\\TTiTTulares',DIR=path.join(HOME,'editorial-tab-watch');
const TIMEOUT=8500;
function read(p){try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}}
function route(raw){
  try{
    const u=new URL(raw);
    if(u.hostname!=='chatgpt.com')return 'external';
    if(/^\/g\/g-p-[a-z0-9-]+\/?$/i.test(u.pathname)||/^\/project\/[a-z0-9-]+\/?$/i.test(u.pathname))return 'project-landing';
    if(/(?:^|\/)c\/[^/]+/.test(u.pathname))return 'conversation';
    if(u.pathname.startsWith('/images'))return 'images-gallery';
    if(u.pathname==='/')return 'home';
    return 'other-chatgpt';
  }catch{return 'unknown'}
}
const simple='(()=>({ready:document.readyState,path:location.pathname,visible:document.visibilityState}))()';
const activity='(()=>{const m=document.querySelectorAll("[data-message-author-role]");const a=document.querySelectorAll("[data-message-author-role=assistant]");const stop=!!document.querySelector("button[data-testid=stop-button]")||!!document.querySelector("[aria-busy=true]");const editor=document.querySelector("#prompt-textarea,[data-testid=prompt-textarea],textarea,[contenteditable=true][role=textbox]");return {ready:document.readyState,messages:m.length,assistant:a.length,busy:stop,draftChars:String(editor?.innerText||editor?.value||"").trim().length}})()';
async function inspect(t){
  if(typeof WebSocket!=='function'||!t.webSocketDebuggerUrl)return {status:'NO_WEBSOCKET'};
  return new Promise(resolve=>{
    let ws,ended=false,stage='connect',start=Date.now();
    const timer=setTimeout(()=>finish({status:'TIMEOUT',stage}),TIMEOUT);
    function finish(obj){if(ended)return;ended=true;clearTimeout(timer);try{ws?.close()}catch{}resolve({...obj,elapsed:Date.now()-start})}
    try{
      ws=new WebSocket(t.webSocketDebuggerUrl);
      ws.addEventListener('open',()=>{
        stage='simple-evaluate';
        try{ws.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{expression:simple,returnByValue:true}}))}
        catch(e){finish({status:'SEND_ERROR',stage,error:String(e.message||e).slice(0,100)})}
      });
      ws.addEventListener('message',e=>{
        try{
          const r=JSON.parse(String(e.data));
          if(r.id!==1&&r.id!==2)return;
          if(r.error||r.result?.exceptionDetails)return finish({status:'CDP_ERROR',stage,message:String(r.error?.message||r.result?.exceptionDetails?.text||'error').slice(0,120)});
          const v=r.result?.result?.value;
          if(!v)return finish({status:'NO_VALUE',stage});
          if(r.id===1){
            stage='activity-evaluate';
            ws.send(JSON.stringify({id:2,method:'Runtime.evaluate',params:{expression:activity,returnByValue:true}}));
          }else finish({status:'OK',...v});
        }catch(ex){finish({status:'PARSE_ERROR',stage,message:String(ex.message||ex).slice(0,100)})}
      });
      ws.addEventListener('error',()=>finish({status:'WS_ERROR',stage}));
      ws.addEventListener('close',()=>finish({status:'WS_CLOSED',stage}));
    }catch(e){finish({status:'WS_SETUP_ERROR',error:String(e.message||e).slice(0,100)})}
  })
}
async function main(){
  const response=await fetch(BASE+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(8500)});
  if(!response.ok)throw Error('CDP HTTP '+response.status);
  const all=await response.json();
  if(!Array.isArray(all))throw Error('CDP returned invalid list');
  const files=fs.existsSync(DIR)?fs.readdirSync(DIR).filter(n=>/^[a-f0-9-]{16,80}\.json$/i.test(n)):[];
  const imagePins=new Set(['ttittulares-image-tab.json','ttendencias-image-tab.json'].map(n=>read(path.join(HOME,n))?.target_id).filter(Boolean));
  console.log('EDITORIAL_DIAG_V1 read_only=true cdp_pages='+all.filter(t=>t.type==='page').length+' tracked_jobs='+files.length);
  const rows=[];
  let index=0;
  await Promise.all(Array.from({length:Math.min(2,files.length)},async()=>{
    while(index<files.length){
      const i=index++,j=read(path.join(DIR,files[i]));
      if(!j?.id){rows[i]={id:files[i].slice(0,16),status:'INVALID_JOB'};continue}
      const target=all.find(x=>x.type==='page'&&x.id===j.id);
      const row={id:String(j.id).slice(0,16),minutes:Math.max(0,Math.round((Date.now()-Number(j.created||Date.now()))/60000)),route:route(target?.url||j.url),present:!!target,pinned:imagePins.has(j.id),idleSamples:Number(j.landingSamples||0),stable:!!j.firstStable};
      row.inspect=target?await inspect(target):{status:'TARGET_MISSING'};
      rows[i]=row;
      const v=row.inspect;
      console.log('TAB id='+row.id+' age='+row.minutes+'m route='+row.route+' present='+row.present+' pinned='+row.pinned+' stage='+(v.stage||'-')+' status='+v.status+' ms='+(v.elapsed||0)+' ready='+(v.ready||'?')+' messages='+(v.messages??'?')+' assistant='+(v.assistant??'?')+' busy='+(v.busy??'?')+' draft='+(v.draftChars??'?'));
    }
  }));
  const counts={};for(const r of rows){const state=r.inspect?.status||r.status||'unknown';counts[state]=(counts[state]||0)+1}
  console.log('SUMMARY '+JSON.stringify(counts));
  const out=path.join(process.env.LOCALAPPDATA||os.tmpdir(),'TT_Recuperacion');
  fs.mkdirSync(out,{recursive:true});
  const file=path.join(out,'editorial-diagnose-'+new Date().toISOString().replace(/[:.]/g,'-')+'.json');
  fs.writeFileSync(file,JSON.stringify({at:new Date().toISOString(),counts,rows},null,2));
  console.log('REPORT '+file);
  console.log('NO_CHANGES to Chrome, queues, tabs or images');
}
main().catch(e=>{console.error('DIAG_ERROR '+String(e.stack||e));process.exitCode=1});
