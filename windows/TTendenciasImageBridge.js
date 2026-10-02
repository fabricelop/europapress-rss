// TTendenciasImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const RUN_URL="https://europapress-rss.vercel.app/api/ttendencias-run";
const JOB_URL="https://europapress-rss.vercel.app/api/ttendencias-run-status?view=image-job&id=";
const commandId=String(process.argv[2]||"").trim();
const targetId=String(process.argv[3]||"").trim();
const secret=String(process.env.TT_IMAGE_UPLOAD_SECRET||"");
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
const COMPOSER_SELECTOR='#prompt-textarea,[data-testid="prompt-textarea"],[contenteditable="true"][data-lexical-editor="true"],[contenteditable="true"][role="textbox"],div[contenteditable="true"]:not([aria-hidden="true"]),textarea:not([disabled])';

async function inspectChat(cdp){
  return cdp.eval("(()=>{const turns=[...document.querySelectorAll('[data-message-author-role]')];const user=turns.some(el=>el.getAttribute('data-message-author-role')==='user'&&(el.innerText||'').includes("+JSON.stringify(commandId)+"));const body=String(document.body&&document.body.innerText||'');const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");return {hasUser:user,hasMarker:body.includes("+JSON.stringify(commandId)+"),hasComposer:Boolean(composer),ttendencias:/TTendencias/i.test(document.title+' '+body.slice(0,7000)),title:document.title||'',url:location.href}})()")
}
async function findChat(){
  const deadline=Date.now()+45000,start=Date.now();
  let best=null,bestScore=-1,bestInfo=null;
  while(Date.now()<deadline){
    let list=[];try{list=await targets()}catch{await sleep(800);continue}
    for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
      const c=new CDP(t.webSocketDebuggerUrl);
      try{
        await c.open();
        const st=await inspectChat(c);
        if(st&&st.hasUser&&st.hasComposer)return c;
        if(st&&st.hasComposer){
          const score=(st.hasMarker?100:0)+(st.ttendencias?30:0)+(String(st.url||"").includes("/g/")?10:0)+5;
          if(score>bestScore){best=t;bestScore=score;bestInfo=st}
        }
      }catch{}
      c.close()
    }
    if(Date.now()-start>=9000&&best&&bestScore>=5){
      const c=new CDP(best.webSocketDebuggerUrl);
      try{
        await c.open();
        const st=await inspectChat(c);
        if(st&&st.hasComposer)return c
      }catch{}
      c.close();
      best=null;bestScore=-1;bestInfo=null;
    }
    await sleep(900)
  }
  throw Error("No se encontró un chat de TTendencias con compositor real"+(bestInfo?(" · "+String(bestInfo.title||bestInfo.url||"").slice(0,120)):""))
}
async function hasUserCommand(cdp){
  return Boolean(await cdp.eval("(()=>[...document.querySelectorAll('[data-message-author-role=\"user\"]')].some(el=>(el.innerText||'').includes("+JSON.stringify(commandId)+")))()"))
}
async function prepareComposer(cdp){
  return cdp.eval("(()=>{const el=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");if(!el)return {ok:false};el.focus();try{if(el.tagName==='TEXTAREA'||el.tagName==='INPUT'){el.setSelectionRange(0,String(el.value||'').length)}else{const r=document.createRange(),s=window.getSelection();r.selectNodeContents(el);s.removeAllRanges();s.addRange(r)}}catch(_){}return {ok:true,tag:el.tagName,testid:el.getAttribute('data-testid')||'',role:el.getAttribute('role')||''}})()")
}
async function ensureCommandSent(cdp,message){
  if(await hasUserCommand(cdp))return {already:true};

  const prepared=await prepareComposer(cdp);
  if(!prepared||!prepared.ok){
    const e=Error("Chat cambió o recargó antes del envío; compositor no disponible");
    e.code="COMPOSER_MISSING";
    throw e
  }

  await cdp.call("Input.insertText",{text:message});
  await sleep(450);
  const filled=await cdp.eval("(()=>{const el=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const v=String(el&&(el.value||el.innerText||el.textContent)||'');return v.includes("+JSON.stringify(commandId)+")})()");
  if(!filled){
    const e=Error("El compositor existe pero no aceptó el comando de imagen");
    e.code="COMPOSER_REJECTED";
    throw e
  }

  async function submitComposer(){
    return cdp.eval("(()=>{const el=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");if(!el)return {ok:false,via:'no-composer'};const root=el.closest('form')||el.parentElement?.parentElement?.parentElement||document;const qs=['button[data-testid=\"send-button\"]','button[data-testid=\"composer-submit-button\"]','button[type=\"submit\"]','button[aria-label*=\"Send\" i]','button[aria-label*=\"Enviar\" i]','button[title*=\"Send\" i]','button[title*=\"Enviar\" i]'];for(const q of qs){const b=root.querySelector?.(q)||document.querySelector(q);if(b&&!b.disabled&&b.getAttribute('aria-disabled')!=='true'){b.click();return {ok:true,via:'click',selector:q,testid:b.getAttribute('data-testid')||'',aria:b.getAttribute('aria-label')||''}}}const form=el.closest('form');if(form&&typeof form.requestSubmit==='function'){const submit=[...form.querySelectorAll('button')].find(b=>!b.disabled&&b.getAttribute('aria-disabled')!=='true'&&(b.type==='submit'||/send|enviar/i.test((b.getAttribute('aria-label')||'')+' '+(b.getAttribute('data-testid')||'')+' '+(b.title||''))));try{form.requestSubmit(submit||undefined);return {ok:true,via:'requestSubmit'}}catch(_){}}const buttons=[...document.querySelectorAll('button')].slice(-40).map(b=>({testid:b.getAttribute('data-testid')||'',aria:b.getAttribute('aria-label')||'',title:b.title||'',type:b.type||'',disabled:Boolean(b.disabled||b.getAttribute('aria-disabled')==='true')}));return {ok:false,via:'no-submit',buttons}})()")
  }

  let submit=await submitComposer();
  if(!submit?.ok){
    await cdp.call("Input.dispatchKeyEvent",{type:"rawKeyDown",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13,text:"\r",unmodifiedText:"\r"});
    await cdp.call("Input.dispatchKeyEvent",{type:"keyUp",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
  }

  const deadline=Date.now()+30000;
  let retried=false;
  while(Date.now()<deadline){
    try{
      if(await hasUserCommand(cdp))return {already:false,submit};
      if(!retried&&Date.now()>deadline-22000){
        retried=true;
        submit=await submitComposer();
        if(!submit?.ok){
          await cdp.call("Input.dispatchKeyEvent",{type:"rawKeyDown",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13,text:"\r",unmodifiedText:"\r"});
          await cdp.call("Input.dispatchKeyEvent",{type:"keyUp",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
        }
      }
    }catch(e){
      const er=Error("La pestaña de ChatGPT cambió durante el envío");
      er.code="CHAT_TARGET_CHANGED";
      throw er
    }
    await sleep(700)
  }
  const detail=submit&&submit.buttons?JSON.stringify(submit.buttons).slice(-900):JSON.stringify(submit||{});
  throw Error("El comando quedó en el compositor, pero no apareció como turno de usuario en 30 segundos; submit="+detail)
}
async function attachAndEnsureCommand(message){
  let last=null;
  for(let attempt=1;attempt<=3;attempt++){
    let cdp=null;
    try{
      cdp=await findChat();
      const sent=await ensureCommandSent(cdp,message);
      return {cdp,sent,attempt}
    }catch(e){
      last=e;
      try{cdp&&cdp.close()}catch{}
      console.log("BRIDGE REATTACH "+attempt+" :: "+String(e&&e.message||e));
      if(attempt<3)await sleep(1800)
    }
  }
  throw last||Error("No se pudo enlazar con el chat de imagen")
}

function probeExpression(){
  return [
    "(async()=>{",
    "const command="+JSON.stringify(commandId)+";",
    "const turns=[...document.querySelectorAll('[data-message-author-role]')];",
    "const user=turns.find(el=>el.getAttribute('data-message-author-role')==='user'&&(el.innerText||'').includes(command));",
    "if(!user)return {found:false,diag:{turns:turns.length,assistants:0,imagesAfterUser:0,candidates:0,canvases:0,assistantTail:'',missingUser:true}};",
    "const follows=el=>Boolean(user.compareDocumentPosition(el)&Node.DOCUMENT_POSITION_FOLLOWING);",
    "const assistants=turns.filter(el=>el.getAttribute('data-message-author-role')==='assistant'&&follows(el));",
    "const allImgs=[...document.querySelectorAll('img')].filter(follows);",
    "const imgs=allImgs.map(img=>{const r=img.getBoundingClientRect(),src=String(img.currentSrc||img.src||''),alt=String(img.alt||'').toLowerCase(),nw=Number(img.naturalWidth||0),nh=Number(img.naturalHeight||0);return {img,r,src,alt,nw,nh,area:Math.max(nw*nh,r.width*r.height)}}).filter(x=>x.r.width>=240&&x.r.height>=140&&!/avatar|emoji|icon|logo/.test(x.alt)&&!x.src.includes('avatar')).sort((a,b)=>b.area-a.area);",
    "const canvases=[...document.querySelectorAll('canvas')].filter(follows).map(el=>{const r=el.getBoundingClientRect();return {el,r,area:r.width*r.height}}).filter(x=>x.r.width>=320&&x.r.height>=180).sort((a,b)=>b.area-a.area);",
    "const diag={turns:turns.length,assistants:assistants.length,imagesAfterUser:allImgs.length,candidates:imgs.length,canvases:canvases.length,assistantTail:assistants.map(x=>(x.innerText||'').trim()).filter(Boolean).join(' | ').slice(-500)};",
    "if(!imgs.length){if(canvases.length){const r=canvases[0].r;return {found:true,kind:'canvas',width:Math.round(r.width),height:Math.round(r.height),rect:{x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height},diag}};return {found:false,diag};}",
    "const c=imgs[0],img=c.img,src=c.src,r=c.r;",
    "const info={found:true,kind:'img',width:c.nw||Math.round(r.width),height:c.nh||Math.round(r.height),rect:{x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height},diag};",
    "try{const rr=await fetch(src,{credentials:'include'});if(rr.ok){const blob=await rr.blob();if(blob.size>=4096&&blob.size<=1900000){const u8=new Uint8Array(await blob.arrayBuffer());let bin='';for(let i=0;i<u8.length;i+=32768)bin+=String.fromCharCode(...u8.subarray(i,i+32768));info.dataUrl='data:'+(blob.type||'image/png')+';base64,'+btoa(bin);info.capture='original-fetch';return info}}}catch(_){}",
    "try{if(c.nw>=640&&c.nh>=360){const max=1400,scale=Math.min(1,max/Math.max(c.nw,c.nh)),w=Math.round(c.nw*scale),h=Math.round(c.nh*scale),cv=document.createElement('canvas');cv.width=w;cv.height=h;cv.getContext('2d',{alpha:false}).drawImage(img,0,0,w,h);for(const q of [0.9,0.84,0.76,0.68]){const data=cv.toDataURL('image/jpeg',q);if(data.length<=2600000){info.dataUrl=data;info.width=w;info.height=h;info.capture='canvas-jpeg-'+q;return info}}}}catch(_){}",
    "return info;",
    "})()"
  ].join("\n")
}

async function capture(cdp){
  const deadline=Date.now()+2*60*1000;
  let lastDiag=null,lastEvalError=null;
  while(Date.now()<deadline){
    let p;try{p=await cdp.eval(probeExpression(),true)}catch(e){lastEvalError=String(e&&e.message||e)}
    if(p&&p.diag)lastDiag=p.diag;
    if(p&&p.dataUrl&&p.width>=640&&p.height>=360)return p;
    if(p&&p.found&&p.rect&&p.rect.width>=320&&p.rect.height>=180){
      try{
        const cap=await cdp.call("Page.captureScreenshot",{format:"jpeg",quality:92,fromSurface:true,clip:{x:p.rect.x,y:p.rect.y,width:p.rect.width,height:p.rect.height,scale:1}});
        const w=Math.round(p.rect.width),h=Math.round(p.rect.height);
        if(cap&&cap.data&&cap.data.length<=2600000&&w>=640&&h>=360)return {dataUrl:"data:image/jpeg;base64,"+cap.data,width:w,height:h,capture:"cdp-element-screenshot",diag:p.diag||null}
      }catch{}
    }
    await sleep(1800)
  }
  const diag=lastDiag?JSON.stringify(lastDiag).slice(0,350):(lastEvalError?("eval_error="+lastEvalError):"sin diagnóstico DOM");
  throw Error("No apareció un raster capturable en 2 minutos; "+diag)
}
async function post(body){
  const r=await fetch(RUN_URL,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  let d={};try{d=await r.json()}catch{}
  return {ok:r.ok,status:r.status,data:d}
}
async function fail(reason){
  try{await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"failed",worker_id:"ttendencias-image-bridge-v1",upload_secret:secret,reason:String(reason||"").slice(0,220)})}catch{}
}
(async()=>{
  let cdp;
  try{
    console.log("BRIDGE START "+commandId);
    const job=await fetchJob();
    const message=buildMessage(job);
    const attached=await attachAndEnsureCommand(message);
    cdp=attached.cdp;
    console.log("BRIDGE CHAT FOUND attempt="+attached.attempt);
    console.log("BRIDGE COMMAND "+(attached.sent.already?"PRESENT":"RESENT"));
    const image=await capture(cdp);
    if(image.width<640||image.height<360)throw Error("Raster capturado inferior a 640x360");
    console.log("BRIDGE IMAGE "+image.capture+" "+image.width+"x"+image.height);
    const up=await post({task:"image_upload",target_id:targetId,command_id:commandId,upload_secret:secret,image_data_url:image.dataUrl,capture:{method:image.capture,width:image.width,height:image.height}});
    if(!up.ok)throw Error("Upload "+up.status+": "+(up.data&&up.data.error||"sin detalle"));
    console.log("BRIDGE UPLOADED "+up.data.sha256);
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