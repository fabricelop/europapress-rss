// TTendenciasImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const RUN_URL="https://europapress-rss.vercel.app/api/ttendencias-run";
const JOB_URL="https://europapress-rss.vercel.app/api/ttendencias-run-status?view=image-job&strong=1&id=";
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
const BRIDGE_MODE="capture-only-v9";

async function inspectChat(cdp){
  return cdp.eval("(()=>{const body=String(document.body&&document.body.innerText||'');const marker=body.includes("+JSON.stringify(commandId)+");const generating=Boolean(document.querySelector('button[data-testid=\"stop-button\"],button[aria-label*=\"Stop\" i],button[aria-label*=\"Detener\" i],button[aria-label*=\"Cancelar\" i]'));const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\"conversation-turn-\"],article').length;return {hasMarker:marker,generating,turns,title:document.title||'',url:location.href}})()")
}

async function findChat(){
  const deadline=Date.now()+60000;
  let best=null,bestScore=-1,bestInfo=null;
  while(Date.now()<deadline){
    let list=[];try{list=await targets()}catch{await sleep(700);continue}
    for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
      const c=new CDP(t.webSocketDebuggerUrl);
      try{
        await c.open();
        const st=await inspectChat(c);
        if(st&&st.hasMarker){
          console.log("BRIDGE TARGET MARKER "+String(st.url||""));
          return c
        }
        const score=(st&&st.generating?40:0)+(st&&/TTendencias/i.test(String(st.title||""))?15:0)+(String(st&&st.url||"").includes("/c/")?5:0);
        if(score>bestScore){best=t;bestScore=score;bestInfo=st}
      }catch{}
      c.close()
    }
    await sleep(900)
  }
  const detail=bestInfo?JSON.stringify(bestInfo).slice(0,500):"sin candidato";
  throw Error("No se encontró el chat lanzado con el command_id en 60 segundos; "+detail)
}

function probeExpression(){
  return [
    "(async()=>{",
    "const command="+JSON.stringify(commandId)+";",
    "const root=document.querySelector('main')||document.body;",
    "const turnSel='[data-message-author-role],[data-testid^=\"conversation-turn-\"],article';",
    "const turnNodes=[...root.querySelectorAll(turnSel)];",
    "let anchor=turnNodes.find(el=>String(el.innerText||el.textContent||'').includes(command))||null;",
    "if(!anchor){",
    " const nodes=[...root.querySelectorAll('div,p,span')].filter(el=>{const t=String(el.innerText||el.textContent||'');return t.includes(command)&&t.length<5000});",
    " nodes.sort((a,b)=>String(a.innerText||a.textContent||'').length-String(b.innerText||b.textContent||'').length);",
    " const leaf=nodes[0]||null;anchor=leaf?(leaf.closest(turnSel)||leaf):null;",
    "}",
    "const generating=Boolean(document.querySelector('button[data-testid=\"stop-button\"],button[aria-label*=\"Stop\" i],button[aria-label*=\"Detener\" i],button[aria-label*=\"Cancelar\" i]'));",
    "if(!anchor)return {found:false,diag:{marker:false,turns:turnNodes.length,generating,imagesAfterMarker:0,candidates:0,canvases:0,assistantTail:''}};",
    "const follows=el=>el!==anchor&&Boolean(anchor.compareDocumentPosition(el)&Node.DOCUMENT_POSITION_FOLLOWING);",
    "const afterTurns=turnNodes.filter(follows);",
    "const allImgs=[...document.querySelectorAll('img')].filter(follows);",
    "const imgs=allImgs.map(img=>{const r=img.getBoundingClientRect(),src=String(img.currentSrc||img.src||''),alt=String(img.alt||'').toLowerCase(),nw=Number(img.naturalWidth||0),nh=Number(img.naturalHeight||0);return {img,r,src,alt,nw,nh,area:Math.max(nw*nh,r.width*r.height)}}).filter(x=>x.r.width>=240&&x.r.height>=140&&!/avatar|emoji|icon|logo|profile/.test(x.alt)&&!x.src.includes('avatar')).sort((a,b)=>b.area-a.area);",
    "const canvases=[...document.querySelectorAll('canvas')].filter(follows).map(el=>{const r=el.getBoundingClientRect();return {el,r,area:r.width*r.height}}).filter(x=>x.r.width>=320&&x.r.height>=180).sort((a,b)=>b.area-a.area);",
    "const tail=afterTurns.map(x=>String(x.innerText||x.textContent||'').trim()).filter(Boolean).join(' | ').slice(-700);",
    "const diag={marker:true,turns:turnNodes.length,afterTurns:afterTurns.length,generating,imagesAfterMarker:allImgs.length,candidates:imgs.length,canvases:canvases.length,assistantTail:tail};",
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
        const scale=Math.min(2.5,Math.max(1,640/Math.max(1,p.rect.width),360/Math.max(1,p.rect.height)));
        for(const quality of [90,82,74]){
          const cap=await cdp.call("Page.captureScreenshot",{format:"jpeg",quality,fromSurface:true,clip:{x:p.rect.x,y:p.rect.y,width:p.rect.width,height:p.rect.height,scale}});
          const w=Math.round(p.rect.width*scale),h=Math.round(p.rect.height*scale);
          if(cap&&cap.data&&cap.data.length<=2600000&&w>=640&&h>=360)return {dataUrl:"data:image/jpeg;base64,"+cap.data,width:w,height:h,capture:"cdp-element-screenshot-x"+scale.toFixed(2)+"-q"+quality,diag:p.diag||null}
        }
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
    void job;
    cdp=await findChat();
    console.log("BRIDGE CHAT FOUND mode="+BRIDGE_MODE);
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