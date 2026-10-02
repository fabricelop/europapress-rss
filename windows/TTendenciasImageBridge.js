// TTendenciasImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const RUN_URL="https://europapress-rss.vercel.app/api/ttendencias-run";
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
async function findChat(){
  const deadline=Date.now()+90000;
  while(Date.now()<deadline){
    let list=[];try{list=await targets()}catch{await sleep(1000);continue}
    for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
      const c=new CDP(t.webSocketDebuggerUrl);
      try{
        await c.open();
        const expr="Boolean(document.body&&document.body.innerText&&document.body.innerText.includes("+JSON.stringify(commandId)+"))";
        if(await c.eval(expr))return c;
      }catch{}
      c.close()
    }
    await sleep(1200)
  }
  throw Error("No se encontró el chat del job")
}

function probeExpression(){
  return [
    "(async()=>{",
    "const command="+JSON.stringify(commandId)+";",
    "const turns=[...document.querySelectorAll('[data-message-author-role]')];",
    "let scope=document;",
    "const ui=turns.findIndex(el=>el.getAttribute('data-message-author-role')==='user'&&(el.innerText||'').includes(command));",
    "if(ui>=0){const a=turns.slice(ui+1).filter(el=>el.getAttribute('data-message-author-role')==='assistant').at(-1);if(a)scope=a;}",
    "const imgs=[...scope.querySelectorAll('img')].filter(img=>{const w=Number(img.naturalWidth||0),h=Number(img.naturalHeight||0),alt=String(img.alt||'').toLowerCase(),src=String(img.currentSrc||img.src||'');return img.complete&&w>=512&&h>=256&&!/avatar|emoji|icon|logo/.test(alt)&&!src.includes('avatar')}).sort((a,b)=>(b.naturalWidth*b.naturalHeight)-(a.naturalWidth*a.naturalHeight));",
    "if(!imgs.length)return {found:false};",
    "const img=imgs[0],src=img.currentSrc||img.src,rect=img.getBoundingClientRect();",
    "const info={found:true,width:img.naturalWidth,height:img.naturalHeight,rect:{x:rect.left+scrollX,y:rect.top+scrollY,width:rect.width,height:rect.height}};",
    "try{const rr=await fetch(src,{credentials:'include'});if(rr.ok){const blob=await rr.blob();if(blob.size>=4096&&blob.size<=1900000){const u8=new Uint8Array(await blob.arrayBuffer());let bin='';for(let i=0;i<u8.length;i+=32768)bin+=String.fromCharCode(...u8.subarray(i,i+32768));info.dataUrl='data:'+(blob.type||'image/png')+';base64,'+btoa(bin);info.capture='original-fetch';return info}}}catch(_){}",
    "try{const max=1400,scale=Math.min(1,max/Math.max(img.naturalWidth,img.naturalHeight)),w=Math.round(img.naturalWidth*scale),h=Math.round(img.naturalHeight*scale),cv=document.createElement('canvas');cv.width=w;cv.height=h;cv.getContext('2d',{alpha:false}).drawImage(img,0,0,w,h);for(const q of [0.9,0.84,0.76,0.68]){const data=cv.toDataURL('image/jpeg',q);if(data.length<=2600000){info.dataUrl=data;info.width=w;info.height=h;info.capture='canvas-jpeg-'+q;return info}}}catch(_){}",
    "return info;",
    "})()"
  ].join("\\n")
}

async function capture(cdp){
  const deadline=Date.now()+7*60*1000;
  while(Date.now()<deadline){
    let p;try{p=await cdp.eval(probeExpression(),true)}catch{}
    if(p&&p.dataUrl&&p.width>=640&&p.height>=360)return p;
    if(p&&p.found&&p.rect&&p.rect.width>=320&&p.rect.height>=180){
      try{
        const cap=await cdp.call("Page.captureScreenshot",{format:"jpeg",quality:90,fromSurface:true,clip:{x:p.rect.x,y:p.rect.y,width:p.rect.width,height:p.rect.height,scale:1}});
        if(cap&&cap.data&&cap.data.length<=2600000)return {dataUrl:"data:image/jpeg;base64,"+cap.data,width:Math.round(p.rect.width),height:Math.round(p.rect.height),capture:"cdp-element-screenshot"}
      }catch{}
    }
    await sleep(1800)
  }
  throw Error("No apareció un raster capturable en 7 minutos")
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
    cdp=await findChat();
    console.log("BRIDGE CHAT FOUND");
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