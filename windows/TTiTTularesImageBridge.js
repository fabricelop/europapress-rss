// TTiTTularesImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const RUN_URL="https://europapress-rss.vercel.app/api/ttittulares-run";
const JOB_URL="https://europapress-rss.vercel.app/api/ttittulares-run-status?view=image-job&strong=1&id=";
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
  call(method,params={},timeoutMs=4000){
    const id=++this.seq;
    return new Promise((ok,bad)=>{
      this.pending.set(id,{ok,bad});
      this.ws.send(JSON.stringify({id,method,params}));
      setTimeout(()=>{if(this.pending.delete(id))bad(Error("CDP timeout "+method))},Math.max(800,Number(timeoutMs)||4000));
    })
  }
  async eval(expression,awaitPromise=false){
    const r=await this.call("Runtime.evaluate",{expression,returnByValue:true,awaitPromise,userGesture:true},4500);
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

async function readFixedTabState(){
  try{
    const fs=await import("node:fs/promises");
    return JSON.parse(await fs.readFile(FIXED_TAB_STATE,"utf8"));
  }catch{return {}}
}
async function writeFixedTabState(t){
  try{
    const fs=await import("node:fs/promises");
    await fs.writeFile(FIXED_TAB_STATE,JSON.stringify({
      version:1,target_id:String(t&&t.id||""),url:String(t&&t.url||""),
      updated_at:new Date().toISOString()
    },null,2)+"\n","utf8")
  }catch(e){console.log("BRIDGE FIXED TAB STATE WARNING :: "+String(e&&e.message||e))}
}
async function createFixedTarget(){
  // Vía preferida: Browser CDP -> Target.createTarget. Es estable y mantiene
  // exactamente la misma sesión/perfil de Chrome que ya está autenticada.
  try{
    const vr=await fetch(BASE_CDP+"/json/version",{cache:"no-store",signal:AbortSignal.timeout(5000)});
    if(!vr.ok)throw Error("CDP /json/version "+vr.status);
    const vd=await vr.json();
    const ws=String(vd&&vd.webSocketDebuggerUrl||"");
    if(!ws)throw Error("browser websocket ausente");
    const browser=new CDP(ws);
    await browser.open();
    let made;
    try{made=await browser.call("Target.createTarget",{url:CHAT_ROOT,newWindow:false,background:false},10000)}
    finally{browser.close()}
    const targetId=String(made&&made.targetId||"");
    if(!targetId)throw Error("Target.createTarget sin targetId");
    const deadline=Date.now()+10000;
    while(Date.now()<deadline){
      const list=await targets();
      const t=list.find(x=>String(x&&x.id||"")===targetId&&x.type==="page"&&x.webSocketDebuggerUrl);
      if(t){
        await writeFixedTabState(t);
        console.log("BRIDGE FIXED TAB CREATED target="+String(t.id)+" via=Target.createTarget");
        return t
      }
      await sleep(250)
    }
    throw Error("Target creado pero no apareció en /json/list")
  }catch(e){
    console.log("BRIDGE FIXED TAB CREATE PRIMARY WARNING :: "+String(e&&e.message||e))
  }

  // Compatibilidad para Chromes que no permitan Target.createTarget en el
  // browser websocket.
  const url=BASE_CDP+"/json/new?"+encodeURIComponent(CHAT_ROOT);
  let r;
  try{r=await fetch(url,{method:"PUT",cache:"no-store",signal:AbortSignal.timeout(5000)})}catch{}
  if(!r||!r.ok){
    try{r=await fetch(url,{cache:"no-store",signal:AbortSignal.timeout(5000)})}catch{}
  }
  if(!r||!r.ok)throw Error("No se pudo crear pestaña dedicada CDP");
  const t=await r.json();
  if(!t||!t.id||!t.webSocketDebuggerUrl)throw Error("CDP creó una pestaña sin target válido");
  await writeFixedTabState(t);
  console.log("BRIDGE FIXED TAB CREATED target="+String(t.id)+" via=json-new");
  return t
}

async function fixedTarget(createIfMissing=true){
  const list=await targets();
  const st=await readFixedTabState();
  let t=list.find(x=>String(x&&x.id||"")===String(st&&st.target_id||"")&&x.type==="page"&&x.webSocketDebuggerUrl);
  if(t){
    console.log("BRIDGE FIXED TAB REUSE target="+String(t.id)+" url="+String(t.url||""));
    return t
  }
  if(!createIfMissing)return null;
  return createFixedTarget()
}
async function waitComposer(cdp,timeoutMs=60000){
  const deadline=Date.now()+timeoutMs;
  let last=null;
  while(Date.now()<deadline){
    try{
      last=await cdp.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");return {composer:!!c,url:location.href,title:document.title||'',ready:document.readyState}})()");
      if(last&&last.composer)return last
    }catch(e){last={error:String(e&&e.message||e)}}
    await sleep(750)
  }
  throw Error("La pestaña dedicada no mostró compositor en "+timeoutMs+" ms; "+JSON.stringify(last||{}).slice(0,400))
}
async function openFreshDedicatedConversation(){
  let t=await fixedTarget(true);
  await progress("fixed_tab","Pestaña física dedicada disponible: "+String(t.id));
  let cdp=new CDP(t.webSocketDebuggerUrl);
  try{
    await cdp.open();
    try{await cdp.call("Page.enable",{},5000)}catch{}
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    try{await cdp.call("Page.navigate",{url:CHAT_ROOT},30000)}catch(e){console.log("BRIDGE PAGE NAVIGATE WARNING :: "+String(e&&e.message||e))}
    await waitComposer(cdp,60000);
    await progress("composer_ready","ChatGPT cargado en la pestaña fija; compositor disponible.");
    // Si ChatGPT restaurase una conversación previa al navegar a raíz, pulsa "Nuevo chat"
    // dentro de LA MISMA pestaña. El target CDP no cambia.
    try{
      const st=await cdp.eval("(()=>({url:location.href}))()");
      if(st&&/\/c\//.test(String(st.url||""))){
        await cdp.eval("(()=>{const els=[...document.querySelectorAll('a,button')];const b=els.find(x=>/new chat|nuevo chat/i.test(String(x.getAttribute('aria-label')||x.getAttribute('title')||x.innerText||'')));if(!b)return false;b.click();return true})()");
        await sleep(700);
        await waitComposer(cdp,30000)
      }
    }catch{}
    const meta=await cdp.eval("(()=>({url:location.href,title:document.title||''}))()");
    console.log("BRIDGE FIXED TAB FRESH CONVERSATION target="+String(t.id)+" url="+String(meta&&meta.url||""));
    return cdp
  }catch(e){
    try{cdp.close()}catch{}
    // El target persistido pudo morir entre /json/list y la conexión. Crear uno nuevo una sola vez.
    t=await createFixedTarget();
    cdp=new CDP(t.webSocketDebuggerUrl);
    await cdp.open();
    try{await cdp.call("Page.enable",{},5000)}catch{}
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    try{await cdp.call("Page.navigate",{url:CHAT_ROOT},30000)}catch(e){console.log("BRIDGE PAGE NAVIGATE WARNING :: "+String(e&&e.message||e))}
    await waitComposer(cdp,60000);
    await progress("composer_ready","Pestaña fija recreada; compositor disponible.");
    console.log("BRIDGE FIXED TAB RECOVERED target="+String(t.id));
    return cdp
  }
}
async function reconnectFixedConversation(job){
  const t=await fixedTarget(false);
  if(!t)return null;
  const c=new CDP(t.webSocketDebuggerUrl);
  try{
    await c.open();
    const st=await inspectChat(c,job);
    return {cdp:c,state:st}
  }catch{try{c.close()}catch{};return null}
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
  const ctx=(job&&job.context_snapshot)||{};
  const tweet=String(ctx.tweet_text||"");
  const remate=String(ctx.remate||"");
  const factual=String(ctx.factual_summary||"");
  const style=String(ctx.image_style||"").trim()||"Más gag, menos barroquismo. Una sola idea visual fuerte, composición limpia, pocos elementos protagonistas, acabado cuidado y estilo editorial variable; evita ilustración literal.";
  const styleName=String(ctx.image_style_name||"variable").trim();
  return [
    "TTITTULARES_IMAGE_JOB_V4 "+commandId+" "+targetId+" | Usa ImageGen AHORA y genera UNA SOLA imagen GAG IA para '"+name+"'.",
    "",
    "TEXTO EXACTO DE LA NOTICIA YA LISTA (NO LO REESCRIBAS):",
    tweet,
    "",
    "REMATE EXACTO:",
    remate,
    "",
    "CONTEXTO FACTUAL COMPLEMENTARIO:",
    factual,
    "",
    "DIRECCIÓN VISUAL ASIGNADA ("+styleName+"):",
    style,
    "",
    "CONSTRUCCIÓN OBLIGATORIA: primero decide internamente cuál es el gag central. La imagen debe expresar UNA sola idea fuerte, entenderse en 1-2 segundos y tener pocos elementos protagonistas. Bien dibujada y pulida, pero sin barroquismo ni decoración innecesaria. El remate visual debe traducir la guindilla; evita añadir símbolos, carteles u objetos que no refuercen directamente ese único chiste.",
    "No inventes hechos externos. No hagas una infografía, interfaz, diagrama, collage ni captura de pantalla. No escribas el tuit dentro de la imagen. Genera exactamente UNA imagen. No proceses otra noticia ni persistas la imagen: el puente local recoge el raster."
  ].join("\n")
}

const BRIDGE_MODE="capture-only-v28-dead-submit-retry";
// compatibility during hot rollout: BRIDGE_MODE="capture-only-v23-target-handoff"
const FIXED_TAB_STATE="C:\\TTiTTulares\\ttittulares-image-tab.json";
const CHAT_ROOT="https://chatgpt.com/";
const BRIDGE_FEATURES="v28-reject-nonconversation-image-targets";
// compatibility: BRIDGE SUBMIT VERIFY WARNING
// compatibility: BRIDGE_MODE="capture-only-v20-command-bound"
// compatibility: BRIDGE_MODE="capture-only-v21-command-scoped"
// compatibility: BRIDGE_MODE="capture-only-v22-command-scoped-cdp-recover"
const COMPOSER_SELECTOR='#prompt-textarea,[data-testid="prompt-textarea"],[contenteditable="true"][data-lexical-editor="true"],[contenteditable="true"][role="textbox"],textarea:not([disabled])';

async function inspectChat(cdp,job){
  const targetName=String(job&&job.target_name||"").trim();
  return cdp.eval("(()=>{const command="+JSON.stringify(commandId)+";const targetName="+JSON.stringify(targetName)+";const root=document.querySelector('main')||document.body;const bodyText=String((document.body&&document.body.innerText)||'');const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const composerText=String(composer&&(composer.innerText||composer.textContent||composer.value)||'');const composerMarker=composerText.includes(command);const nodes=[...root.querySelectorAll('div,p,span,article,[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"]')].filter(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;const t=String(el.innerText||el.textContent||'');return t.includes(command)});const bodyMarker=nodes.length>0;const markerOutsideComposer=bodyMarker;const targetMarker=!!targetName&&bodyText.toLocaleLowerCase().includes(targetName.toLocaleLowerCase());const generating=Boolean(document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]'));const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length;const largeImages=[...document.images].filter(img=>Number(img.naturalWidth||0)>=640&&Number(img.naturalHeight||0)>=360);const images=largeImages.length;const imageSrc=largeImages.length?String(largeImages[0].currentSrc||largeImages[0].src||''):'';const title=document.title||'';const imageTitle=/Generar imagen IA|Generate image|Image generation/i.test(title);return {hasMarker:markerOutsideComposer,bodyMarker,composerMarker,targetMarker,imageTitle,generating,turns,images,imageSrc,title,url:location.href}})()")
}


async function injectPromptIntoChat(cdp,job){
  const message=buildMessage(job);
  try{
    const before=await domImageCandidates(cdp);
    cdp.preSubmitImageSrcs=new Set(before.map(x=>x.src));
    console.log("BRIDGE SELF-SUBMIT BASELINE images="+before.length);
  }catch{}
  const prep=await cdp.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");if(!c)return {ok:false};c.focus();try{if(c.tagName==='TEXTAREA'||c.tagName==='INPUT'){c.value='';c.dispatchEvent(new Event('input',{bubbles:true}))}else{const s=getSelection();const r=document.createRange();r.selectNodeContents(c);s.removeAllRanges();s.addRange(r);document.execCommand('delete',false,null)}}catch(_){}return {ok:true,url:location.href,title:document.title||''}})()");
  if(!prep||!prep.ok)throw Error("No hay compositor utilizable para fallback");
  await cdp.call("Input.insertText",{text:message});
  await sleep(250);
  const verify=await cdp.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const t=String(c&&(c.innerText||c.textContent||c.value)||'');return {ok:t.includes("+JSON.stringify(commandId)+"),len:t.length,url:location.href,title:document.title||''}})()");
  if(!verify||!verify.ok)throw Error("Fallback no pudo escribir el prompt completo");
  console.log("BRIDGE SELF-SUBMIT PROMPT INJECTED "+String(verify.url||""));
  return cdp
}

async function findFallbackComposerChat(job){
  let list=[];try{list=await targets()}catch{return null}
  const pages=list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl);
  const ranked=pages.map(t=>{
    const meta=(String(t.title||"")+" "+String(t.url||""));
    const opposite=/TTendencias/i.test(meta)&&!/TTiTTulares/i.test(meta);
    const imageish=/Generar imagen|Gag IA|Image generation|Imagen IA/i.test(meta);
    const projectish=/TTiTTulares/i.test(meta);
    const score=(isPostLaunchTarget(t)?1800:0)+(imageish?1000:0)+(projectish?600:0)+(String(t.url||"").includes("/c/")?100:0)-(opposite?3000:0);
    return {t,score}
  }).filter(x=>x.score>-1000).sort((a,b)=>b.score-a.score).slice(0,3);
  for(const item of ranked){
    const c=new CDP(item.t.webSocketDebuggerUrl);
    try{
      await c.open();
      const st=await c.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");return {composer:!!c,title:document.title||'',url:location.href}})()");
      if(st&&st.composer)return {c,st,score:item.score}
    }catch{}
    c.close()
  }
  return null
}

async function findChat(job){
  const deadline=Date.now()+8000;
  while(Date.now()<deadline){
    const hinted=await hintedTarget();
    if(hinted){
      const hc=new CDP(hinted.webSocketDebuggerUrl);
      try{
        await hc.open();
        const st=await hc.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length;return {composer:!!c,turns,title:document.title||'',url:location.href}})()");
        if(st&&(st.composer||st.turns>0)){
          console.log("BRIDGE TARGET HINT CONVERSATION "+String(st.url||hinted.url||"")+" turns="+Number(st.turns||0));
          return hc
        }
        console.log("BRIDGE TARGET HINT REJECTED non-conversation "+String(st&&st.url||hinted.url||""));
      }catch{}
      hc.close()
    }
    let list=[];try{list=await targets()}catch{await sleep(500);continue}
    const fresh=list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl&&isPostLaunchTarget(x));
    fresh.sort((a,b)=>{
      const sa=(String(a.url||"").includes("/c/")?500:0)+(/TTendencias|TTiTTulares/i.test(String(a.title||""))?200:0)-(/Generar imagen|Image generation/i.test(String(a.title||""))?300:0);
      const sb=(String(b.url||"").includes("/c/")?500:0)+(/TTendencias|TTiTTulares/i.test(String(b.title||""))?200:0)-(/Generar imagen|Image generation/i.test(String(b.title||""))?300:0);
      return sb-sa
    });
    for(const t of fresh.slice(0,4)){
      const fc=new CDP(t.webSocketDebuggerUrl);
      try{
        await fc.open();
        const st=await fc.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length;return {composer:!!c,turns,title:document.title||'',url:location.href}})()");
        if(st&&(st.composer||st.turns>0)){
          console.log("BRIDGE TARGET POST-LAUNCH CONVERSATION "+String(st.url||t.url||"")+" turns="+Number(st.turns||0));
          return fc
        }
        console.log("BRIDGE TARGET POST-LAUNCH REJECTED non-conversation "+String(st&&st.url||t.url||""));
      }catch{}
      fc.close()
    }
    await sleep(500)
  }
  const fallback=await findFallbackComposerChat(job);
  if(fallback&&fallback.c){
    console.log("BRIDGE SELF-SUBMIT FALLBACK conversation="+String(fallback.st&&fallback.st.url||""));
    return fallback.c
  }
  throw Error("No se encontró ninguna conversación ChatGPT válida con compositor")
}

async function reacquireCommandChat(job){
  const fixed=await reconnectFixedConversation(job);
  if(fixed&&fixed.cdp){console.log("BRIDGE REACQUIRE FIXED TAB "+String(fixed.state&&fixed.state.url||""));return fixed}

  const hinted=await hintedTarget();
  if(hinted){
    const hc=new CDP(hinted.webSocketDebuggerUrl);
    try{
      await hc.open();
      const hs=await inspectChat(hc,job);
      if(hs&&(hs.bodyMarker||hs.composerMarker))return {cdp:hc,state:hs}
    }catch{}
    hc.close()
  }
  let list=[];try{list=await targets()}catch{return null}
  for(const t of list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl)){
    const c=new CDP(t.webSocketDebuggerUrl);
    try{
      await c.open();
      const st=await inspectChat(c,job);
      if(st&&(st.bodyMarker||st.composerMarker))return {cdp:c,state:st}
    }catch{}
    c.close()
  }
  return null
}

async function ensureSubmitted(cdp,job){
  const deadline=Date.now()+45000;
  let current=cdp,last=null,lastAttemptAt=0,reacquires=0,triggeredAt=0;
  while(Date.now()<deadline){
    let st=null;
    try{
      st=await current.eval("(()=>{const command="+JSON.stringify(commandId)+";const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const composerText=String(composer&&(composer.innerText||composer.textContent||composer.value)||'');const composerMarker=composerText.includes(command);const root=document.querySelector('main')||document.body;const bodyText=String((root&&root.innerText)||'');const userTurns=[...root.querySelectorAll('[data-message-author-role=\"user\"],[data-testid*=\"user\" i],[class*=\"user-message\" i]')].filter(el=>String(el.innerText||el.textContent||'').includes(command));const submitted=userTurns.length>0;const generating=Boolean(document.querySelector('button[data-testid=\"stop-button\"],button[aria-label*=\"Stop\" i],button[aria-label*=\"Detener\" i],button[aria-label*=\"Cancelar\" i]'));const send=document.querySelector('button[data-testid=\"send-button\"],button[aria-label*=\"Send\" i],button[aria-label*=\"Enviar\" i],form button[type=\"submit\"]');const inConversation=/\\/c\\//.test(location.pathname);const commandOutsideComposer=bodyText.includes(command)&&!composerMarker;return {composerMarker,submitted,userTurns:userTurns.length,generating,inConversation,commandOutsideComposer,send:!!send,sendDisabled:!!(send&&send.disabled),url:location.href,title:document.title||''}})()");
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
    const strongTransition=Boolean(
      st && triggeredAt &&
      st.inConversation &&
      !st.composerMarker &&
      (st.generating || st.commandOutsideComposer) &&
      (Date.now()-triggeredAt)>=500
    );

    if(st&&(st.submitted||strongTransition)){
      current.submissionVerified=true;
      current.acceptInitialRaster=true;
      console.log("BRIDGE SUBMIT VERIFIED mode="+(st.submitted?"user-turn":"conversation-transition")+" generating="+Boolean(st.generating)+" url="+String(st.url||""));
      return current
    }

    if(st&&st.composerMarker&&Date.now()-lastAttemptAt>=1200){
      lastAttemptAt=Date.now();
      let triggered=false;
      try{
        triggered=Boolean(await current.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const b=document.querySelector('button[data-testid=\"send-button\"],button[aria-label*=\"Send\" i],button[aria-label*=\"Enviar\" i],form button[type=\"submit\"]');if(b&&!b.disabled){b.click();return true}const form=c&&c.closest&&c.closest('form');if(form&&typeof form.requestSubmit==='function'){form.requestSubmit();return true}return false})()"));
      }catch{}
      if(!triggered){
        try{
          const focused=Boolean(await current.eval("(()=>{const c=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");if(!c)return false;c.focus();return true})()"));
          if(focused){
            await current.call("Input.dispatchKeyEvent",{type:"keyDown",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
            await current.call("Input.dispatchKeyEvent",{type:"char",text:"\r",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
            await current.call("Input.dispatchKeyEvent",{type:"keyUp",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});
            triggered=true;
          }
        }catch{}
      }
      if(triggered&&!triggeredAt)triggeredAt=Date.now();
      console.log("BRIDGE SUBMIT RECOVERY "+(triggered?"TRIGGERED":"WAIT")+" sendDisabled="+Boolean(st.sendDisabled)+" generating="+Boolean(st.generating));
    }

    await sleep(650);
  }
  throw Error("No hubo evidencia suficiente de envío del prompt ImageGen; "+JSON.stringify(last||{}).slice(0,700))
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

async function domImageCandidates(cdp){
  const out=[];
  try{
    const doc=await cdp.call("DOM.getDocument",{depth:0,pierce:true});
    const root=doc&&doc.root&&doc.root.nodeId;
    if(!root)return out;
    const q=await cdp.call("DOM.querySelectorAll",{nodeId:root,selector:"img"});
    const ids=Array.isArray(q&&q.nodeIds)?q.nodeIds.slice(-14):[];
    for(const nodeId of ids){
      try{
        const a=await cdp.call("DOM.getAttributes",{nodeId});
        const arr=Array.isArray(a&&a.attributes)?a.attributes:[];
        const attrs={};for(let i=0;i+1<arr.length;i+=2)attrs[String(arr[i])]=String(arr[i+1]);
        const src=String(attrs.src||attrs["data-src"]||attrs["data-original"]||"");
        if(!src)continue;
        const box=await cdp.call("DOM.getBoxModel",{nodeId});
        const quad=(box&&box.model&&(box.model.border||box.model.content))||null;
        if(!Array.isArray(quad)||quad.length<8)continue;
        const xs=[quad[0],quad[2],quad[4],quad[6]].map(Number),ys=[quad[1],quad[3],quad[5],quad[7]].map(Number);
        const x=Math.min(...xs),y=Math.min(...ys),w=Math.max(...xs)-x,h=Math.max(...ys)-y;
        if(!(w>=180&&h>=120))continue;
        out.push({nodeId,src,alt:String(attrs.alt||""),x,y,width:w,height:h,area:w*h});
      }catch{}
    }
  }catch(e){
    console.log("BRIDGE DOM IMAGE SCAN WARNING :: "+String(e&&e.message||e))
  }
  out.sort((a,b)=>(b.y+b.height)-(a.y+a.height)||b.area-a.area);
  return out
}
async function captureDomImage(cdp,candidate){
  const scale=Math.min(3,Math.max(1,640/Math.max(1,candidate.width),360/Math.max(1,candidate.height)));
  for(const quality of [92,86,78]){
    try{
      const cap=await cdp.call("Page.captureScreenshot",{format:"jpeg",quality,fromSurface:true,clip:{x:candidate.x,y:candidate.y,width:candidate.width,height:candidate.height,scale}});
      const w=Math.round(candidate.width*scale),h=Math.round(candidate.height*scale);
      if(cap&&cap.data&&cap.data.length>=16000&&cap.data.length<=3900000&&w>=640&&h>=360){
        return {dataUrl:"data:image/jpeg;base64,"+cap.data,width:w,height:h,capture:"image-element-screenshot-cdp-x"+scale.toFixed(2)+"-q"+quality,diag:{src:candidate.src.slice(0,180),nodeId:candidate.nodeId}}
      }
    }catch{}
  }
  return null
}

async function capture(cdp,job){
  const deadline=Date.now()+3*60*1000;
  let lastDiag=null,lastEvalError=null,baselineSet=false,baselineSrc="",deadSince=0;
  const acceptInitialRaster=Boolean(cdp&&cdp.acceptInitialRaster);
  let domBaseline=(cdp&&cdp.preSubmitImageSrcs instanceof Set)?new Set(cdp.preSubmitImageSrcs):new Set();
  try{
    const initial=await domImageCandidates(cdp);
    if(!domBaseline.size)domBaseline=new Set(initial.map(x=>x.src));
    console.log("BRIDGE DOM BASELINE images="+initial.length);
  }catch{}
  while(Date.now()<deadline){
    // v25: nunca hacemos screenshot del DOM. La interfaz de ChatGPT puede
    // superponerse al <img> (Preview, Ask ChatGPT, controles) y contaminar
    // el resultado. Solo se aceptan bytes del recurso o canvas del <img>.
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
    if(p&&p.diag){
      lastDiag=p.diag;
      const dead=Boolean(p.diag.marker&&p.diag.commandScoped&&!p.diag.generating&&Number(p.diag.imagesAfterMarker||0)===0&&Number(p.diag.turns||0)===0);
      if(dead){
        if(!deadSince)deadSince=Date.now();
        if(Date.now()-deadSince>=15000)throw Error("ImageGen quedó inactivo tras el envío; "+JSON.stringify(p.diag).slice(0,700))
      }else deadSince=0;
    }
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
    // Sin fallback de screenshot: si fetch/canvas no produce raster limpio,
    // esperamos hasta timeout y fallamos de forma explícita.
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
async function progress(phase,detail){
  try{
    const r=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"progress",worker_id:"ttittulares-image-bridge-v28-dead-submit-retry",phase:String(phase||"pc_progress"),detail:String(detail||"").slice(0,220)});
    if(!r.ok)console.log("BRIDGE PROGRESS ACK WARNING "+String(phase)+" "+r.status+" "+String(r.data&&r.data.error||""))
  }catch(e){console.log("BRIDGE PROGRESS WARNING "+String(phase)+" :: "+String(e&&e.message||e))}
}
async function fail(reason){
  try{await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"failed",worker_id:"ttittulares-image-bridge-v28-dead-submit-retry",upload_secret:secret,reason:String(reason||"").slice(0,220)})}catch{}
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
    cdp=await openFreshDedicatedConversation();
    console.log("BRIDGE FIXED CHAT READY mode="+BRIDGE_MODE);
    let image=null;
    for(let generationAttempt=1;generationAttempt<=2;generationAttempt++){
      if(generationAttempt>1){
        try{cdp&&cdp.close()}catch{}
        await progress("image_retry","Primer envío no produjo generación real; reintentando en conversación nueva de la misma pestaña.");
        cdp=await openFreshDedicatedConversation();
        console.log("BRIDGE INTERNAL RETRY conversation="+generationAttempt);
      }
      cdp=await injectPromptIntoChat(cdp,job);
      cdp=await ensureSubmitted(cdp,job);
      cdp.acceptInitialRaster=true;
      console.log("BRIDGE FIXED PROMPT SUBMITTED/VERIFIED attempt="+generationAttempt);
      if(generationAttempt===1){
        await progress("prompt_sent","Prompt GAG IA enviado y verificado en conversación nueva de la pestaña fija.");
        const launched=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"launched",worker_id:"ttittulares-image-bridge-v28-dead-submit-retry"});
        if(!launched.ok)console.log("BRIDGE LAUNCHED ACK WARNING "+launched.status+" "+String(launched.data&&launched.data.error||""));
      }
      await progress("capture_wait","Esperando el raster generado por ImageGen en la misma pestaña. Intento "+generationAttempt+"/2.");
      try{
        image=await capture(cdp,job);
        break
      }catch(e){
        if(generationAttempt>=2)throw e;
        console.log("BRIDGE GENERATION RETRY :: "+String(e&&e.message||e));
      }
    }
    if(!image)throw Error("ImageGen no produjo raster tras reintento interno");
    await progress("raster_captured","Raster ImageGen capturado; validando y materializando.");
    if(image.width<1024||image.height<576)throw Error("Raster capturado inferior a 1024x576");
    if(!/^(original-fetch-img|canvas-from-img-)/.test(String(image.capture||"")))throw Error("Método de captura no permitido: "+String(image.capture||""));
    console.log("BRIDGE CLEAN IMAGE "+image.capture+" "+image.width+"x"+image.height);
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
      const done=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"done",worker_id:"ttittulares-image-bridge-v28-dead-submit-retry",upload_secret:secret});
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
