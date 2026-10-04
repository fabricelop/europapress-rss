// TTendenciasImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const RUN_URL="https://europapress-rss.vercel.app/api/ttendencias-run";
const JOB_URL="https://europapress-rss.vercel.app/api/ttendencias-run-status?view=image-job&strong=1&id=";
const commandId=String(process.argv[2]||"").trim();
const targetId=String(process.argv[3]||"").trim();
const secret=String(process.env.TT_IMAGE_UPLOAD_SECRET||"");
const targetHintFile=String(process.env.TT_IMAGE_TARGET_HINT_FILE||"").trim();
const prelaunchSnapshotProvided=Object.prototype.hasOwnProperty.call(process.env,"TT_IMAGE_PRELAUNCH_TARGETS_JSON");
let prelaunchTargets=new Map();
try{
  const parsed=JSON.parse(String(process.env.TT_IMAGE_PRELAUNCH_TARGETS_JSON||"[]"));
  const rows=Array.isArray(parsed)?parsed:(parsed&&typeof parsed==="object"?[parsed]:[]);
  prelaunchTargets=new Map(rows.map(x=>[
    String(x&&x.id||""),
    {url:String(x&&x.url||""),title:String(x&&x.title||"")}
  ]).filter(x=>x[0]));
}catch{}
function isPostLaunchTarget(t){
  if(!prelaunchSnapshotProvided)return false;
  const id=String(t&&t.id||""),url=String(t&&t.url||""),title=String(t&&t.title||"");
  if(!prelaunchTargets.has(id))return true;
  const before=prelaunchTargets.get(id)||{};
  return String(before.url||"")!==url || (!!String(before.title||"") && String(before.title||"")!==title)
}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
if(!commandId||!targetId||secret.length<32)throw Error("Argumentos incompletos");
if(typeof WebSocket==="undefined")throw Error("Node sin WebSocket global");

class CDP{
  constructor(url){this.url=url;this.ws=null;this.seq=0;this.pending=new Map()}
  async open(){
    this.ws=new WebSocket(this.url);
    await new Promise((ok,bad)=>{
      const t=setTimeout(()=>bad(Error("Timeout CDP")),7000);
      this.ws.addEventListener("open",()=>{clearTimeout(t);ok()},{once:true});
      this.ws.addEventListener("error",()=>{clearTimeout(t);bad(Error("Error CDP"))},{once:true});
    });
    this.ws.addEventListener("message",ev=>{
      let m;try{m=JSON.parse(String(ev.data))}catch{return}
      const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);
      m.error?p.bad(Error(m.error.message||"CDP error")):p.ok(m.result)
    });
  }
  call(method,params={}){
    const id=++this.seq;
    return new Promise((ok,bad)=>{
      this.pending.set(id,{ok,bad});
      this.ws.send(JSON.stringify({id,method,params}));
      setTimeout(()=>{if(this.pending.delete(id))bad(Error("CDP timeout "+method))},12000);
    })
  }
  async eval(expression,awaitPromise=false){
    const r=await this.call("Runtime.evaluate",{expression,returnByValue:true,awaitPromise,userGesture:true});
    if(r&&r.exceptionDetails)throw Error(r.exceptionDetails.text||"Runtime.evaluate");
    return r&&r.result?r.result.value:undefined
  }
  close(){try{this.ws&&this.ws.close()}catch{}}
}

async function readTargetHint(){
  if(!targetHintFile)return null;
  try{
    const fs=await import("node:fs/promises");
    const txt=await fs.readFile(targetHintFile,"utf8");
    const d=JSON.parse(txt);
    const id=String(d&&d.target_id||"").trim();
    if(!id)return null;
    return {id,url:String(d&&d.url||""),title:String(d&&d.title||"")}
  }catch{return null}
}
async function hintedTarget(){
  const hint=await readTargetHint();
  if(!hint)return null;
  let list=[];try{list=await targets()}catch{return null}
  const t=list.find(x=>String(x&&x.id||"")===hint.id && x.webSocketDebuggerUrl);
  if(!t)return null;
  return t
}

async function targets(){
  const r=await fetch(BASE_CDP+"/json/list",{cache:"no-store"});
  if(!r.ok)throw Error("CDP /json/list "+r.status);
  return r.json()
}
async function fetchJob(){
  const r=await fetch(JOB_URL+encodeURIComponent(targetId)+"&t="+Date.now(),{cache:"no-store"});
  if(!r.ok)throw Error("Job "+r.status);
  const d=await r.json();
  if(!d||!d.ok||String(d.command_id||"")!==commandId)throw Error("Job de imagen no disponible o sustituido");
  return d
}
function buildMessage(job){
  const name=String(job&&job.target_name||targetId);
  return "TT_IMAGE_JOB_V3 "+commandId+" "+targetId+" | Usa ImageGen AHORA y genera UNA imagen IA para '"+name+"': gag visual cómico, satírico, irónico y exagerado, no una ilustración literal. Lee trends/image-runs/jobs/"+targetId+".json en control/ttendencias-run-trigger para el contexto exacto. No proceses otra entrada ni persistas la imagen: el puente local recoge el raster."
}
const BRIDGE_MODE="capture-only-v23-target-handoff";
// compatibility: BRIDGE_MODE="capture-only-v20-command-bound"
// compatibility: BRIDGE_MODE="capture-only-v21-command-scoped"
// compatibility: BRIDGE_MODE="capture-only-v22-command-scoped-cdp-recover"
const COMPOSER_SELECTOR='#prompt-textarea,[data-testid="prompt-textarea"],[contenteditable="true"][data-lexical-editor="true"],[contenteditable="true"][role="textbox"],textarea:not([disabled])';

async function inspectChat(cdp,job){
  const targetName=String(job&&job.target_name||"").trim();
  return cdp.eval("(()=>{const command="+JSON.stringify(commandId)+";const targetName="+JSON.stringify(targetName)+";const root=document.querySelector('main')||document.body;const bodyText=String((document.body&&document.body.innerText)||'');const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const composerText=String(composer&&(composer.innerText||composer.textContent||composer.value)||'');const composerMarker=composerText.includes(command);const nodes=[...root.querySelectorAll('div,p,span,article,[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"]')].filter(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;const t=String(el.innerText||el.textContent||'');return t.includes(command)});const bodyMarker=nodes.length>0;const markerOutsideComposer=bodyMarker;const targetMarker=!!targetName&&bodyText.toLocaleLowerCase().includes(targetName.toLocaleLowerCase());const generating=Boolean(document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]'));const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length;const largeImages=[...document.images].filter(img=>Number(img.naturalWidth||0)>=640&&Number(img.naturalHeight||0)>=360);const images=largeImages.length;const imageSrc=largeImages.length?String(largeImages[0].currentSrc||largeImages[0].src||''):'';const title=document.title||'';const imageTitle=/Generar imagen IA|Generate image|Image generation/i.test(title);return {hasMarker:markerOutsideComposer,bodyMarker,composerMarker,targetMarker,imageTitle,generating,turns,images,imageSrc,title,url:location.href}})()")
}

async function findChat(job){
  const deadline=Date.now()+90000;
  let best=null,bestScore=-1,bestInfo=null;
  const baselineImageSrc=new Map();
  const baselineState=new Map();
  let baselinePass=true;
  while(Date.now()<deadline){
    const hinted=await hintedTarget();
    if(hinted){
      const hc=new CDP(hinted.webSocketDebuggerUrl);
      try{
        await hc.open();
        const hs=await inspectChat(hc,job);
        console.log("BRIDGE TARGET HINT "+String(hs&&hs.url||hinted.url||"")+" id="+String(hinted.id||""));
        hc.acceptInitialRaster=true;
        return hc
      }catch{hc.close()}
    }
    let list=[];try{list=await targets()}catch{await sleep(700);continue}
    const imageTitleCandidates=[];
    for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
      const postLaunch=isPostLaunchTarget(t);
      const c=new CDP(t.webSocketDebuggerUrl);
      try{
        await c.open();
        const st=await inspectChat(c,job);
        const tid=String(t&&t.id||"");
        const currentImageSrc=String(st&&st.imageSrc||"");
        if(baselinePass){
          baselineImageSrc.set(tid,currentImageSrc);
          baselineState.set(tid,{
            targetMarker:Boolean(st&&st.targetMarker),
            turns:Number(st&&st.turns||0),
            title:String(st&&st.title||""),
            url:String(st&&st.url||"")
          });
        }else{
          const before=baselineState.get(tid)||null;
          const chatChanged=Boolean(before)&&(
            (!before.targetMarker&&Boolean(st&&st.targetMarker)) ||
            Number(st&&st.turns||0)>Number(before.turns||0) ||
            String(st&&st.title||"")!==String(before.title||"") ||
            String(st&&st.url||"")!==String(before.url||"")
          );
          if(st&&st.targetMarker&&chatChanged){
            console.log("BRIDGE TARGET CHAT-STATE CHANGE "+String(st.url||""));
            return c
          }
        }
        if(!baselinePass&&st&&st.imageTitle&&currentImageSrc&&baselineImageSrc.has(tid)&&baselineImageSrc.get(tid)!==currentImageSrc){
          console.log("BRIDGE TARGET NEW RASTER "+String(st.url||""));
          c.acceptInitialRaster=true;
          return c
        }else if(st&&st.imageTitle&&currentImageSrc&&!baselineImageSrc.has(tid)){
          console.log("BRIDGE TARGET NEW IMAGE TAB "+String(st.url||""));
          c.acceptInitialRaster=true;
          return c
        }
        if(st&&st.hasMarker){
          console.log("BRIDGE TARGET MARKER "+String(st.url||""));
          return c
        }
        if(st&&st.targetMarker&&postLaunch){
          console.log("BRIDGE TARGET POST-LAUNCH TARGET "+String(st.url||""));
          return c
        }
        const title=String(st&&st.title||"");
        const projectMatch=/TTendencias/i.test(title)&&!/TTiTTulares/i.test(title);
        const oppositeMatch=/TTiTTulares/i.test(title);
        if(st&&st.generating&&postLaunch&&(st.targetMarker||st.imageTitle)){
          console.log("BRIDGE TARGET POST-LAUNCH GENERATING "+String(st.url||""));
          return c
        }
        if(st&&st.imageTitle&&postLaunch){
          console.log("BRIDGE TARGET POST-LAUNCH IMAGE "+String(st.url||""));
          return c
        }
        if(st&&st.imageTitle&&st.targetMarker&&st.images>0){
          console.log("BRIDGE TARGET IMAGE-TITLE "+String(st.url||""));
          return c
        }
        if(st&&st.imageTitle)imageTitleCandidates.push({t,st});
        const score=(postLaunch?900:0)+(st&&st.bodyMarker?1000:0)+(st&&st.targetMarker?650:0)+(st&&st.imageTitle?300:0)+(projectMatch?250:0)+(st&&st.generating&&(st.bodyMarker||st.targetMarker||postLaunch)?100:0)+(st&&st.images>0?40:0)+(String(st&&st.url||"").includes("/c/")?10:0)-(oppositeMatch?1000:0);
        if(score>bestScore){best=t;bestScore=score;bestInfo=st}
      }catch{}
      c.close()
    }
    if(imageTitleCandidates.length===1){
      const only=imageTitleCandidates[0];
      const existingImages=Number(only.st&&only.st.images||0);
      if(existingImages===0&&(isPostLaunchTarget(only.t)||Boolean(only.st&&only.st.targetMarker))){
        const c=new CDP(only.t.webSocketDebuggerUrl);
        try{
          await c.open();
          console.log("BRIDGE TARGET UNIQUE EMPTY IMAGE-TITLE "+String(only.st&&only.st.url||only.t.url||""));
          return c
        }catch{c.close()}
      }
    }
    if(baselinePass){
      baselinePass=false;
      console.log("BRIDGE PRELAUNCH BASELINE targets="+baselineImageSrc.size);
    }
    await sleep(700)
  }
  const detail=bestInfo?JSON.stringify(bestInfo).slice(0,700):"sin candidato";
  throw Error("No se encontró el chat lanzado tras observar cambios de estado en 90 segundos; "+detail)
}

async function reacquireCommandChat(job){
  const hinted=await hintedTarget();
  if(hinted){
    const hc=new CDP(hinted.webSocketDebuggerUrl);
    try{
      await hc.open();
      const hs=await inspectChat(hc,job);
      return {cdp:hc,state:hs}
    }catch{hc.close()}
  }
  let list=[];try{list=await targets()}catch{return null}
  let composerCandidate=null;
  for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
    const c=new CDP(t.webSocketDebuggerUrl);
    try{
      await c.open();
      const st=await inspectChat(c,job);
      if(st&&st.bodyMarker){
        if(composerCandidate){try{composerCandidate.cdp.close()}catch{}}
        return {cdp:c,state:st}
      }
      if(st&&isPostLaunchTarget(t)&&(st.targetMarker||st.imageTitle)){
        if(composerCandidate){try{composerCandidate.cdp.close()}catch{}}
        return {cdp:c,state:st}
      }
      if(st&&st.composerMarker){
        if(composerCandidate){try{composerCandidate.cdp.close()}catch{}}
        composerCandidate={cdp:c,state:st};
        continue
      }
    }catch{}
    c.close()
  }
  return composerCandidate
}

async function ensureSubmitted(cdp,job){
  const deadline=Date.now()+45000;
  let current=cdp,last=null,lastAttemptAt=0,reacquires=0;
  while(Date.now()<deadline){
    let st=null;
    try{
      st=await current.eval("(()=>{const command="+JSON.stringify(commandId)+";const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const composerText=String(composer&&(composer.innerText||composer.textContent||composer.value)||'');const composerMarker=composerText.includes(command);const root=document.querySelector('main')||document.body;const submitted=[...root.querySelectorAll('[data-message-author-role=\\\"user\\\"],[data-testid^=\\\"conversation-turn-\\\"],article')].some(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;return String(el.innerText||el.textContent||'').includes(command)});const generating=Boolean(document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]'));const send=document.querySelector('button[data-testid=\\\"send-button\\\"],button[aria-label*=\\\"Send\\\" i],button[aria-label*=\\\"Enviar\\\" i]');return {composerMarker,submitted,generating,send:!!send,sendDisabled:!!(send&&send.disabled),url:location.href,title:document.title||''}})()");
    }catch{}

    if(!st){
      const found=await reacquireCommandChat(job);
      if(found){
        if(found.cdp!==current){try{current&&current.close()}catch{}}
        current=found.cdp;st=found.state;reacquires++;
        console.log("BRIDGE SUBMIT REACQUIRED "+String(st&&st.url||"")+" count="+reacquires);
      }
    }

    last=st;
    if(st&&(st.submitted||st.generating)){
      current.submissionVerified=true;
      current.acceptInitialRaster=true;
      return current
    }

    if(st&&st.composerMarker&&Date.now()-lastAttemptAt>=1200){
      lastAttemptAt=Date.now();
      let clicked=false;
      try{
        clicked=Boolean(await current.eval("(()=>{const b=document.querySelector('button[data-testid=\\\"send-button\\\"],button[aria-label*=\\\"Send\\\" i],button[aria-label*=\\\"Enviar\\\" i]');if(!b||b.disabled)return false;b.click();return true})()"));
      }catch{}
      if(!clicked){
        try{
          const focused=Boolean(await current.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");if(!c)return false;c.focus();return true})()"));
          if(focused){
            await current.call("Input.dispatchKeyEvent",{type:"keyDown",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
            await current.call("Input.dispatchKeyEvent",{type:"keyUp",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
            clicked=true;
          }
        }catch{}
      }
      console.log("BRIDGE SUBMIT RECOVERY "+(clicked?"TRIGGERED":"WAIT")+" sendDisabled="+Boolean(st.sendDisabled));
    }

    await sleep(650);
  }
  throw Error("El prompt ImageGen quedó sin enviar tras reintentos/relocalización; "+JSON.stringify(last||{}).slice(0,500))
}
function probeExpression(){
  return [
    "(async()=>{",
    "const command="+JSON.stringify(commandId)+";",
    "const root=document.querySelector('main')||document.body;",
    "const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");",
    "const markerNodes=[...root.querySelectorAll('div,p,span,article,[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"]')].filter(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;const t=String(el.innerText||el.textContent||'');return t.includes(command)&&t.length<7000});",
    "const bodyText=String((document.body&&document.body.innerText)||'');",
    "const marker=markerNodes.length>0||bodyText.includes(command);",
    "const generating=Boolean(document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]'));",
    "const commandTurns=[...root.querySelectorAll('[data-message-author-role=\\\"user\\\"],[data-testid^=\\\"conversation-turn-\\\"]')].filter(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;const t=String(el.innerText||el.textContent||'');return t.includes(command)&&t.length<9000});",
    "const markerRef=commandTurns.length?commandTurns[commandTurns.length-1]:(markerNodes.length?markerNodes[markerNodes.length-1]:null);",
    "const afterCommand=img=>{if(!markerRef)return false;try{return Boolean(markerRef.compareDocumentPosition(img)&Node.DOCUMENT_POSITION_FOLLOWING)}catch(_){return false}};",
    "const all=[...root.querySelectorAll('img')].filter(afterCommand).map((img,index)=>{const r=img.getBoundingClientRect(),src=String(img.currentSrc||img.src||''),alt=String(img.alt||''),nw=Number(img.naturalWidth||0),nh=Number(img.naturalHeight||0),vis=r.width>=180&&r.height>=120&&r.bottom>0&&r.right>0;const ratio=nh?nw/nh:0;const area=nw*nh;const sourceScore=/oaiusercontent|openai|blob:|generated|image/i.test(src+' '+alt)?80:0;const altScore=/generated|image|imagen/i.test(alt)?25:0;const sizeScore=Math.min(60,Math.floor(area/25000));const uiPenalty=/avatar|emoji|icon|logo|profile|thumbnail/i.test((alt+' '+src).toLowerCase())?200:0;return {index,img,r,src,alt,nw,nh,ratio,area,vis,score:sourceScore+altScore+sizeScore-uiPenalty}}).filter(x=>x.vis&&x.nw>=640&&x.nh>=360&&x.area>=300000&&x.score>-50).sort((a,b)=>b.score-a.score||b.area-a.area);",
    "const diag={marker,commandScoped:Boolean(markerRef),turns:document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length,generating,imagesAfterMarker:all.length,candidates:all.length,canvases:document.querySelectorAll('canvas').length,top:all.slice(0,3).map(x=>({nw:x.nw,nh:x.nh,ratio:Number(x.ratio.toFixed(3)),alt:x.alt.slice(0,80),src:x.src.slice(0,120),score:x.score}))};",
    "if(!all.length)return {found:false,diag};",
    "const c=all[0],img=c.img,src=c.src,r=c.r;",
    "const info={found:true,kind:'img',src:src.slice(0,1800),width:c.nw,height:c.nh,rect:{x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height},candidateIndex:c.index,diag};",
    "try{const rr=await fetch(src,{credentials:'include'});if(rr.ok){const blob=await rr.blob();if(blob.size>=12000&&blob.size<=3000000&&String(blob.type||'').startsWith('image/')){const u8=new Uint8Array(await blob.arrayBuffer());let bin='';for(let i=0;i<u8.length;i+=32768)bin+=String.fromCharCode(...u8.subarray(i,i+32768));info.dataUrl='data:'+(blob.type||'image/png')+';base64,'+btoa(bin);info.capture='original-fetch-img';return info}}}catch(_){}",
    "try{const max=1600,scale=Math.min(1,max/Math.max(c.nw,c.nh)),w=Math.round(c.nw*scale),h=Math.round(c.nh*scale),cv=document.createElement('canvas');cv.width=w;cv.height=h;const cx=cv.getContext('2d',{alpha:false});cx.drawImage(img,0,0,w,h);for(const q of [0.92,0.86,0.78]){const data=cv.toDataURL('image/jpeg',q);if(data.length>=16000&&data.length<=3900000){info.dataUrl=data;info.width=w;info.height=h;info.capture='canvas-from-img-'+q;return info}}}catch(_){}",
    "return info;",
    "})()"
  ].join("\n")
}
async function capture(cdp,job){
  const deadline=Date.now()+3*60*1000;
  let lastDiag=null,lastEvalError=null,baselineSet=false,baselineSrc="";
  const acceptInitialRaster=Boolean(cdp&&cdp.acceptInitialRaster);
  while(Date.now()<deadline){
    let p;
    try{
      p=await cdp.eval(probeExpression(),true);
    }catch(e){
      lastEvalError=String(e&&e.message||e);
      if(/CDP timeout|WebSocket|closed|not open|Target closed|Inspected target navigated/i.test(lastEvalError)){
        console.log("BRIDGE CAPTURE CDP RECOVER :: "+lastEvalError);
        const found=await reacquireCommandChat(job);
        if(found&&found.cdp){
          try{cdp&&cdp.close()}catch{}
          cdp=found.cdp;
          cdp.acceptInitialRaster=true;
          baselineSet=false;
          baselineSrc="";
          console.log("BRIDGE CAPTURE CDP REACQUIRED "+String(found.state&&found.state.url||""));
          await sleep(500);
          continue
        }
      }
    }
    if(p&&p.diag)lastDiag=p.diag;
    const currentSrc=String(p&&p.src||"");
    if(!baselineSet){
      baselineSet=true;
      baselineSrc=currentSrc;
      if(acceptInitialRaster&&p&&p.dataUrl&&p.width>=640&&p.height>=360){
        console.log("BRIDGE ACCEPT POST-BASELINE RASTER "+currentSrc.slice(0,120));
        return p
      }
      if(baselineSrc)console.log("BRIDGE BASELINE IMAGE IGNORED "+baselineSrc.slice(0,120));
      await sleep(800);
      continue
    }
    const isNewRaster=Boolean(currentSrc)&&(!baselineSrc||currentSrc!==baselineSrc);
    if(p&&p.dataUrl&&p.width>=640&&p.height>=360&&isNewRaster)return p;
    // Fallback seguro: screenshot SOLO del elemento <img> candidato. Nunca del turno,
    // card, canvas o viewport completo.
    if(p&&p.found&&p.kind==="img"&&isNewRaster&&p.rect&&p.rect.width>=180&&p.rect.height>=120){
      try{
        const naturalRatio=Number(p.width||0)/Math.max(1,Number(p.height||1));
        const rectRatio=Number(p.rect.width||0)/Math.max(1,Number(p.rect.height||1));
        if(naturalRatio>=0.7&&naturalRatio<=2.2&&Math.abs(Math.log(Math.max(0.01,naturalRatio)/Math.max(0.01,rectRatio)))<0.45){
          const scale=Math.min(3,Math.max(1,640/Math.max(1,p.rect.width),360/Math.max(1,p.rect.height)));
          for(const quality of [92,86,78]){
            const cap=await cdp.call("Page.captureScreenshot",{format:"jpeg",quality,fromSurface:true,clip:{x:p.rect.x,y:p.rect.y,width:p.rect.width,height:p.rect.height,scale}});
            const w=Math.round(p.rect.width*scale),h=Math.round(p.rect.height*scale);
            if(cap&&cap.data&&cap.data.length>=16000&&cap.data.length<=3900000&&w>=640&&h>=360){
              return {dataUrl:"data:image/jpeg;base64,"+cap.data,width:w,height:h,capture:"image-element-screenshot-x"+scale.toFixed(2)+"-q"+quality,diag:p.diag||null}
            }
          }
        }
      }catch{}
    }
    await sleep(1500)
  }
  const diag=lastDiag?JSON.stringify(lastDiag).slice(0,900):(lastEvalError?("eval_error="+lastEvalError):"sin diagnóstico DOM");
  throw Error("No apareció un raster ImageGen capturable en 3 minutos; "+diag)
}
async function post(body){
  const r=await fetch(RUN_URL,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  let d={};try{d=await r.json()}catch{}
  return {ok:r.ok,status:r.status,data:d}
}
async function fail(reason){
  try{await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"failed",worker_id:"ttendencias-image-bridge-v1",upload_secret:secret,reason:String(reason||"").slice(0,220)})}catch{}
}
async function uploadImage(image){
  let result;
  for(let attempt=1;attempt<=3;attempt++){
    result=await post({task:"image_upload",target_id:targetId,command_id:commandId,upload_secret:secret,image_data_url:image.dataUrl,capture:{method:image.capture,width:image.width,height:image.height}});
    if(result.ok)return result;
    const detail=String(result.data&&result.data.error||"");
    const concurrentMainUpdate=result.status===409||(result.status===500&&/GitHub main binary PUT.*409/i.test(detail));
    if(!concurrentMainUpdate||attempt===3)return result;
    console.log("BRIDGE UPLOAD RETRY "+attempt+" concurrent-main-update");
    await sleep(1500*attempt);
  }
  return result;
}
(async()=>{
  let cdp;
  try{
    console.log("BRIDGE START "+commandId);
    const job=await fetchJob();
    void job;
    cdp=await findChat(job);
    console.log("BRIDGE CHAT FOUND mode="+BRIDGE_MODE);
    try{
      cdp=await ensureSubmitted(cdp,job);
      cdp.acceptInitialRaster=true;
      console.log("BRIDGE PROMPT SUBMITTED/VERIFIED");
    }catch(submitErr){
      // El lanzador y el usuario pueden confirmar que ImageGen sí arrancó aunque
      // la UI de ChatGPT ya haya reemplazado el composer/turno que usamos como prueba.
      // No abortar: volver a localizar el chat y pasar a captura del raster.
      console.log("BRIDGE SUBMIT VERIFY WARNING :: "+String(submitErr&&submitErr.message||submitErr));
      const found=await reacquireCommandChat(job);
      if(found&&found.cdp){
        try{cdp&&cdp.close()}catch{}
        cdp=found.cdp;
        cdp.acceptInitialRaster=Boolean(found.state&&(found.state.bodyMarker||found.state.generating||found.state.imageTitle||found.state.targetMarker));
        console.log("BRIDGE CAPTURE CHAT REACQUIRED "+String(found.state&&found.state.url||""));
      }else{
        // Mantener el target ya localizado: capture() seguirá esperando hasta 3 minutos.
        cdp.acceptInitialRaster=true;
      }
    }
    const image=await capture(cdp,job);
    if(image.width<640||image.height<360)throw Error("Raster capturado inferior a 640x360");
    console.log("BRIDGE IMAGE "+image.capture+" "+image.width+"x"+image.height);
    const up=await uploadImage(image);
    if(!up.ok)throw Error("Upload "+up.status+": "+(up.data&&up.data.error||"sin detalle"));
    console.log("BRIDGE UPLOADED "+up.data.sha256);
    if(String(up.data&&up.data.status||"").toUpperCase()==="DONE"){
      console.log("BRIDGE DONE VIA UPLOAD");
      return
    }
    const deadline=Date.now()+6*60*1000;
    while(Date.now()<deadline){
      await sleep(5000);
      const done=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"done",worker_id:"ttendencias-image-bridge-v1",upload_secret:secret});
      if(done.ok){console.log("BRIDGE DONE");return}
      if(done.status!==409||!done.data||done.data.error!=="image_not_persisted_yet")throw Error("Finalize "+done.status+": "+(done.data&&done.data.error||"sin detalle"))
    }
    throw Error("Outbox recibido pero no materializado en 6 minutos");
  }catch(e){
    console.error("BRIDGE ERROR :: "+String(e&&e.message||e));
    await fail(e&&e.message||e);
    process.exitCode=1;
  }finally{try{cdp&&cdp.close()}catch{}}
})();
