// TTendenciasImageBridge.js
const BASE_CDP="http://127.0.0.1:9223";
const SERVICE_BASE=String(process.env.TTENDENCIAS_SERVICE_BASE||"https://tt-control.fabricelop.workers.dev").replace("https://ttendencias-no-vercel-test.fabricelop.workers.dev","https://tt-control.fabricelop.workers.dev").replace(new RegExp("/+$"),"");
const RUN_URL=SERVICE_BASE+"/api/ttendencias-run";
const JOB_URL=SERVICE_BASE+"/api/ttendencias-run-status?view=image-job&strong=1&id=";
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
  const r=await fetch(BASE_CDP+"/json/list",{cache:"no-store",signal:AbortSignal.timeout(5000)});
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
  // Snapshot targets first: a timed-out Target.createTarget may still have
  // created a tab. Never blindly fall back to /json/new in that case.
  const existingIds=new Set((await targets()).map(x=>String(x&&x.id||"")));
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

  // If Chrome created the target but its CDP acknowledgement was lost,
  // adopt that target rather than opening a duplicate.
  let appeared;
  try{
    appeared=(await targets()).filter(x=>x.type==="page"&&x.webSocketDebuggerUrl&&!existingIds.has(String(x.id||"")))
  }catch(e){
    throw Error("CDP no disponible tras createTarget; no se abrirá otra pestaña: "+String(e&&e.message||e))
  }
  if(appeared.length===1){
    await writeFixedTabState(appeared[0]);
    console.log("BRIDGE FIXED TAB RECOVERED LOST ACK target="+String(appeared[0].id));
    return appeared[0]
  }
  if(appeared.length>1)throw Error("Nuevos targets ambiguos tras timeout; no duplicar pestañas");
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
async function closeFixedTargetById(targetId){
  const id=String(targetId||"").trim();
  if(!id)return;
  try{
    const vr=await fetch(BASE_CDP+"/json/version",{cache:"no-store",signal:AbortSignal.timeout(5000)});
    if(!vr.ok)throw Error("CDP browser version "+vr.status);
    const vd=await vr.json();
    const ws=String(vd&&vd.webSocketDebuggerUrl||"");
    if(!ws)throw Error("CDP browser websocket missing");
    const browser=new CDP(ws);
    await browser.open();
    try{const result=await browser.call("Target.closeTarget",{targetId:id},5000);if(result&&result.success===false)throw Error("Target.closeTarget refused")}finally{browser.close()}
    console.log("BRIDGE FIXED TAB CLOSE REQUESTED target="+id)
  }catch(e){
    console.log("BRIDGE FIXED TAB CLOSE WARNING :: "+String(e&&e.message||e));
    await closeFixedTargetHttp(id);
  }
}
async function closeFixedTargetHttp(targetId){
  const id=String(targetId||"").trim();if(!id)return false;
  // Independent Chrome discovery endpoint, scoped to the exact pinned tab.
  // A close acknowledgement is not proof of closure: caller polls /json/list.
  try{
    const r=await fetch(BASE_CDP+"/json/close/"+encodeURIComponent(id),{cache:"no-store",signal:AbortSignal.timeout(5000)});
    console.log("BRIDGE FIXED TAB HTTP CLOSE target="+id+" status="+r.status);
    return r.ok||r.status===404;
  }catch(e){console.log("BRIDGE FIXED TAB HTTP CLOSE WARNING target="+id);return false;}
}
async function waitFixedTargetClosed(targetId){
  for(let n=0;n<20;n++){
    await sleep(500);
    const living=await targets();
    if(!living.some(x=>x.type==="page"&&String(x.id||"")===String(targetId)))return true;
    // Some frozen renderers never complete the browser websocket close call.
    // Retry only this tab through HTTP, never open a replacement while it lives.
    if(n===4)await closeFixedTargetHttp(targetId);
  }
  return false;
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
// Chrome puede navegar aunque CDP pierda el ACK de Page.navigate.
// No declarar fallida una imagen solo por un timeout de confirmacion;
// verificar a continuacion que ChatGPT haya cargado el compositor.
async function navigateChatBestEffort(cdp){
  try{
    await cdp.call("Page.navigate",{url:CHAT_ROOT},10000);
  }catch(e){
    console.log("BRIDGE NAVIGATE ACK TIMEOUT :: "+String(e&&e.message||e));
    let url="";
    try{
      const st=await cdp.eval("(()=>({url:location.href,ready:document.readyState}))()");
      url=String(st&&st.url||"");
    }catch{}
    if(!url.startsWith("https://chatgpt.com/")){
      try{cdp.fire("Page.navigate",{url:CHAT_ROOT})}catch{}
    }
  }
}

// Reduce renderer churn: prefer ChatGPT's SPA "new chat" over a full reload.
// Only used after the listeners have acquired the exclusive image slot.
async function prepareReusableConversation(cdp){
  const validHome=u=>u==="https://chatgpt.com/"||u==="https://chatgpt.com";
  const inspect=()=>cdp.eval("(()=>({url:location.href,composer:!!document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+")}))()");
  let state=null;
  try{state=await inspect()}catch{}
  if(state&&validHome(String(state.url||""))&&state.composer){
    console.log("BRIDGE FIXED TAB SPA REUSE home-ready");
    return await waitComposer(cdp,60000);
  }
  if(state&&/^https:\/\/chatgpt\.com\/c\/[^/?#]+/.test(String(state.url||""))){
    let clicked=false;
    try{
      clicked=Boolean(await cdp.eval("(()=>{const a=[...document.querySelectorAll('a,button')];const label=x=>String(x.getAttribute('aria-label')||x.getAttribute('title')||x.innerText||'');const b=a.find(x=>/new chat|nuevo chat/i.test(label(x)))||a.find(x=>x.tagName==='A'&&x.getAttribute('href')==='/');if(!b)return false;b.click();return true})()"));
    }catch{}
    if(clicked){
      const deadline=Date.now()+12000;
      while(Date.now()<deadline){
        await sleep(450);
        try{
          const next=await inspect();
          if(next&&validHome(String(next.url||""))&&next.composer){
            console.log("BRIDGE FIXED TAB SPA NEW CHAT confirmed");
            return await waitComposer(cdp,60000);
          }
        }catch{}
      }
      console.log("BRIDGE FIXED TAB SPA NEW CHAT timeout; using navigation fallback");
    }
  }
  // Blank, malformed, unresponsive, or unsupported routes retain the old
  // reliable navigation fallback. Never create another Chrome instance here.
  await navigateChatBestEffort(cdp);
  return await waitComposer(cdp,60000);
}

async function openFreshDedicatedConversation(){
  let t=await fixedTarget(true);
  await progress("fixed_tab","Pestaña física dedicada disponible: "+String(t.id));
  let cdp=new CDP(t.webSocketDebuggerUrl);
  try{
    await cdp.open();
    cdp.fixedTargetId=String(t.id);
    try{await cdp.call("Page.enable",{},5000)}catch{}
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    await prepareReusableConversation(cdp);
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
    // A slow ChatGPT composer must NOT create another tab if the pinned
    // target still exists. Keep the same tab for a later retry.
    let stillPresent=false;
    try{
      const live=await targets();
      stillPresent=live.some(x=>x.type==="page"&&String(x.id||"")===String(t.id||"")&&x.webSocketDebuggerUrl)
    }catch{
      // If CDP is unreachable, creating another target would make things worse.
      console.log("BRIDGE FIXED TAB CHECK FAILED; not opening an additional tab");
      throw e
    }
    if(stillPresent){
      // Target exists but its renderer cannot evaluate JavaScript. Do not
      // restart Chrome or touch the separate TTImageRelay/9234 browser.
      // Recovery is restricted to this bridge's dedicated ChatGPT tab,
      // before writing any prompt for the new job.
      const reason=String(e&&e.message||e);
      if(!/CDP timeout Runtime\.evaluate|La pestaña dedicada no mostró compositor/i.test(reason)){
        console.log("BRIDGE FIXED TAB RETAINED AFTER ERROR target="+String(t.id)+" reason="+reason.slice(0,180));
        throw e
      }
      console.log("BRIDGE FIXED TAB UNRESPONSIVE target="+String(t.id)+" isolated-tab-recovery");
      await closeFixedTargetById(t.id);
      const closed=await waitFixedTargetClosed(t.id);
      if(!closed)throw Error("El target dedicado sigue abierto; no se creará otra pestaña");
      console.log("BRIDGE FIXED TAB ISOLATED RECOVERY CLOSED target="+String(t.id));
    }
    // No new Chrome process, no other tab touched, one replacement maximum.
    t=await createFixedTarget();
    cdp=new CDP(t.webSocketDebuggerUrl);
    await cdp.open();
    cdp.fixedTargetId=String(t.id);
    try{await cdp.call("Page.enable",{},5000)}catch{}
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    await prepareReusableConversation(cdp);
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
  // El ACK ya puede estar aceptado mientras el Worker sirve aún un objeto
  // anterior. Nunca dar por perdido un job sin contrastar la rama GitHub.
  const rawUrl="https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/image-runs/jobs/"+encodeURIComponent(targetId)+".json";
  let lastError="sin respuesta";
  for(let attempt=1;attempt<=4;attempt++){
    const sources=[
      ["worker",JOB_URL+encodeURIComponent(targetId)+"&t="+Date.now()],
      ["github-raw",rawUrl+"?t="+Date.now()+"-"+attempt]
    ];
    for(const [label,url] of sources){
      try{
        const response=await fetch(url,{cache:"no-store",headers:{"cache-control":"no-cache","pragma":"no-cache"},signal:AbortSignal.timeout(12000)});
        if(!response.ok){lastError=label+" HTTP "+response.status;continue}
        const doc=await response.json();
        if(doc&&String(doc.command_id||"")===commandId&&doc.context_snapshot){
          if(label==="github-raw")console.log("BRIDGE JOB RAW RECOVERED target="+targetId+" command="+commandId);
          return {ok:true,...doc}
        }
        lastError=label+" command_id desactualizado o sin contexto";
      }catch(e){lastError=label+" "+String(e&&e.message||e)}
    }
    if(attempt<4)await sleep(1200*attempt)
  }
  throw Error("Job de imagen no disponible tras Worker+GitHub RAW: "+lastError)
}
function buildMessage(job){
  const name=String(job&&job.target_name||targetId);
  const ctx=(job&&job.context_snapshot)||{};
  const explanation=String(ctx.explanation||"");
  const closer=String(ctx.closer_text||"");
  const group=String(ctx.group_title||"");
  const trendNames=Array.isArray(ctx.trend_names)?ctx.trend_names.join(", "):"";
  const sources=Array.isArray(ctx.verification_sources)?ctx.verification_sources.map(x=>String(x&&x.source||"")).filter(Boolean).join(", "):"";
  const style=String(ctx.image_style||"").trim()||"Más gag, menos barroquismo. Una sola idea visual fuerte, composición limpia, pocos elementos protagonistas, acabado cuidado y estilo editorial variable; evita ilustración literal.";
  const styleName=String(ctx.image_style_name||"variable").trim();
  // Keep image creation first and independent. The same receiving chat then
  // owns the authorized Sites return step; no credential travels in a prompt.
  const siteContext={project_id:"appgprj_6ae4dcf7d7488191a574e5b649e67370",target_id:targetId,
    name,revision:Number(job.revision||0),scope:"editorial",explanation:explanation.trim(),
    explained_at:String(ctx.explained_at||"")};
  // ImageGen is not proof of Site delivery. Use the connector actually available
  // in ordinary project chats; the old @Sites route is not a reliable dependency.
  // This handoff is best effort. The independent existing Windows read-only
  // consumer remains the fallback when ImageGen ends a turn before upload.
  const siteReturn=[
    "TTENDENCIAS_SITE_AUTO_RECEIPT_V5 — PASO POSTERIOR A IMAGEGEN. Este mensaje se ha lanzado automáticamente para el command_id "+commandId+". La imagen generada es un resultado INTERMEDIO. Completa la asociación y la sincronización sin pedir otro prompt ni repetir la generación.",
    "SITE EXISTENTE: https://ttactualidad-tendencias.rainyraven22.chatgpt.site/ . Utiliza el conector TTendencias · TTActualidad con las operaciones mcp__TTendencias___TTActualidad__inspect_top30_images, mcp__TTendencias___TTActualidad__attach_trend_image y mcp__TTendencias___TTActualidad__verify_trend_image. NO uses @Sites: no está disponible de forma fiable en estos chats. NO crees otro Site ni publiques otra URL.",
    "CONTEXTO EDITORIAL EXACTO PARA EL OBJETO context: "+JSON.stringify(siteContext)+". Este encargo tiene command_id="+commandId+". No asocies por nombre, tema, rango o fecha aproximada. Si ya existe una imagen diferente para esta misma revisión, no la sustituyas.",
    "1. Después de generar, conserva el PNG original de ESTE encargo y su identificador real. Invoca inspect_top30_images y confirma ID, revisión, explicación literal y explained_at. El estado LAUNCHED del MISMO command_id es esperado: NO lo interpretes como un segundo encargo ni como motivo para abandonar la asociación de este PNG. Si existe un encargo activo de OTRO command_id, la revisión cambió o no puedes acreditar el archivo original, NO adjuntes.",
    "2. Ejecuta attach_trend_image con file igual al PNG ORIGINAL recién generado, y context igual al objeto exacto anterior (project_id, target_id, name, revision, scope, explanation, explained_at). No envíes una URL inventada, una captura de pantalla ni texto en lugar del archivo. Si ya hay una imagen verificada del mismo contexto, evita una segunda asociación y continúa solo con la sincronización.",
    "3. Ejecuta verify_trend_image con ese mismo context. Únicamente si devuelve status: verified y un PNG persistido con URL y SHA-256 reales puedes pasar al catálogo iPhone. Si devuelve missing, conflict o cualquier otro estado, declara SITE PENDING y conserva el archivo sin generar otra imagen.",
    "4. Sincroniza automáticamente la MISMA imagen con TTActualidad iPhone leyendo el archivo trends/site-ai-images.json del repositorio fabricelop/europapress-rss, rama main, usando el conector GitHub (fetch_file). Conserva TODAS las entradas y actualiza exclusivamente la de (target_id, revision) con los valores LITERALES de context: target_id, revision, explanation, explained_at; image_url debe ser https://ttactualidad-tendencias.rainyraven22.chatgpt.site + la ruta REAL obtenida en verify_trend_image, y sha256 debe ser la huella REAL verificada. Usa update_file con el SHA actual; ante conflicto de concurrencia, relee y reconcilia. No borres entradas ajenas.",
    "5. Relee trends/site-ai-images.json desde main y confirma que conserva todos los datos anteriores y la nueva entrada idéntica al Site. Declara APP SYNC VERIFIED solo después de esta comprobación; si GitHub no está conectado, comunica APP SYNC PENDING sin deshacer la asociación del Site.",
    "6. Informa con precisión SITE verified/pending y APP verified/pending. No afirmes que el iPhone la mostró físicamente sin comprobarlo. Si ImageGen termina el turno antes de ejecutar las herramientas, no se ha producido una asociación: el consumidor independiente del PC podrá recuperar el raster original asociado a command_id cuando esté disponible. Nunca prometas que un prompt por sí solo ejecutó el retorno ni solicites un nuevo PNG."
  ].join("\n\n");
  const NO_PEPPER="REGLA VISUAL OBLIGATORIA: el emoji 🌶️ solo es un marcador del remate ESCRITO, nunca un elemento de la imagen. PROHIBIDO representar guindillas, chiles, pimientos picantes, iconos de guindilla, logotipos, mascotas o símbolos equivalentes, ni en fondo, objetos, carteles, ropa, decoraciones o firmas. Convierte exclusivamente el SIGNIFICADO del remate en un gag visual, nunca su emoji.";
  if(String(job.editorial_image_mode||ctx.editorial_image_mode||"")==="rigor"){
    return ["TTENDENCIAS_IMAGE_JOB_V4 "+commandId+" "+targetId+" | Usa ChatGPT Images y genera UNA imagen periodística RIGUROSA y RESPETUOSA sobre '"+name+"'.",
      "CONTEXTO FACTUAL:",explanation,
      "DIRECCIÓN VISUAL:",style,NO_PEPPER,
      "No hagas humor ni sátira. No trivialices víctimas o sufrimiento, no inventes escenas documentales ni personas identificables. Imagen editorial sobria, no gráfica. Ignora el remate humorístico.",siteReturn]
      .join("\\n");
  }
  return [
    "TTENDENCIAS_IMAGE_JOB_V4 "+commandId+" "+targetId+" | Usa ImageGen AHORA y genera UNA SOLA imagen GAG IA para '"+name+"'.",
    "",
    "TEXTO EXACTO DE LA TENDENCIA YA EXPLICADA (NO LO REESCRIBAS):",
    explanation,
    "",
    "REMATE EXACTO:",
    closer,
    "",
    "CONTEXTO COMPLEMENTARIO:",
    "Tendencias relacionadas: "+trendNames,
    group?("Grupo editorial: "+group):"",
    sources?("Fuentes verificadas: "+sources):"",
    "",
    "DIRECCIÓN VISUAL ASIGNADA ("+styleName+"):",
    style,
    NO_PEPPER,
    "",
    "CONSTRUCCIÓN OBLIGATORIA: primero decide internamente cuál es el gag central. La imagen debe expresar UNA sola idea fuerte, entenderse en 1-2 segundos y tener pocos elementos protagonistas. Bien dibujada y pulida, pero sin barroquismo ni decoración innecesaria. El remate visual debe expresar el SIGNIFICADO del chiste, no el emoji de texto; si no hay remate, parte del hecho factual sin inventar otro.",
    "No inventes hechos externos. No hagas infografía, interfaz, diagrama, collage ni captura de pantalla. No escribas la explicación completa dentro de la imagen. Genera exactamente UNA imagen. No proceses otra tendencia.",
    siteReturn
  ].filter(Boolean).join("\n")
}

const BRIDGE_MODE="capture-only-v28-dead-submit-retry";
// compatibility during hot rollout: BRIDGE_MODE="capture-only-v23-target-handoff"
const FIXED_TAB_STATE="C:\\TTiTTulares\\ttendencias-image-tab.json";
const CHAT_ROOT="https://chatgpt.com/";
const BRIDGE_FEATURES="v28-reject-nonconversation-image-targets";
// compatibility: BRIDGE SUBMIT VERIFY WARNING
// compatibility: BRIDGE_MODE="capture-only-v20-command-bound"
// compatibility: BRIDGE_MODE="capture-only-v21-command-scoped"
// compatibility: BRIDGE_MODE="capture-only-v22-command-scoped-cdp-recover"
const BRIDGE_COMPOSER_FIX="v56-atomic-command-scoped-submit";
const COMPOSER_SELECTOR='[data-tt-image-composer="true"],#prompt-textarea,[data-testid="prompt-textarea"],[contenteditable="true"][data-lexical-editor="true"],[contenteditable="true"][role="textbox"],textarea:not([disabled])';

// Pre-submit only. ChatGPT can mount a hidden/stale composer while the fixed
// tab is hydrating; existence alone is NOT readiness to type. Never click a
// draft or navigate away from an already-generating conversation.
async function ensureVisibleComposerBeforeInput(cdp,{maxPolls=12,delayMs=750}={}){
  let last=null;
  const probe="(()=>{const cands=[...document.querySelectorAll("+JSON.stringify(COMPOSER_SELECTOR)+")];"
    +"const read=c=>String(c&&(c.value||c.innerText||c.textContent)||'').trim();"
    +"const good=c=>{try{const r=c.getBoundingClientRect(),s=getComputedStyle(c);return c.isConnected&&!c.disabled&&!c.readOnly&&r.width>12&&r.height>10&&s.display!=='none'&&s.visibility!=='hidden'&&!c.closest('[inert],[aria-hidden=\\\"true\\\"]')}catch{return false}};"
    +"const c=cands.find(x=>x.getAttribute('data-tt-image-composer')==='true'&&good(x))||cands.find(good);"
    +"const generating=!!document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]');"
    +"const title=document.title||'';const blocked=!!document.querySelector('input[type=\\\"password\\\"]')||/log in|sign in|iniciar sesi[oó]n|verify you are human|comprueba que eres humano/i.test(title);"
    +"const sizes=cands.slice(0,4).map(x=>{const r=x.getBoundingClientRect();return [Math.round(r.width),Math.round(r.height)]});"
    +"return {ok:!!c,found:cands.length,sizes,hidden:document.visibilityState==='hidden',generating,blocked,typedDraft:cands.some(x=>read(x).length>0),url:location.href,title:title.slice(0,90)};})()";
  for(let pass=0;pass<2;pass++){
    // Only the dedicated ChatGPT tab is affected; neither Chrome itself nor
    // TTiTTulares or the separate TTImages/CDP 9234 session is touched.
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    for(let n=0;n<maxPolls;n++){
      try{last=await cdp.eval(probe)}catch(e){last={error:String(e&&e.message||e).slice(0,140)}}
      if(last&&last.ok)return last;
      if(last&&(last.generating||last.typedDraft||last.blocked)){
        throw Error("Compositor no disponible: sesión ocupada o requiere intervención; "+JSON.stringify(last).slice(0,420));
      }
      if(n===0||n===maxPolls-1)console.log("BRIDGE VISIBLE COMPOSER PREFLIGHT pass="+pass+" probe="+n+" "+JSON.stringify(last||{}).slice(0,380));
      if(n+1<maxPolls)await sleep(delayMs);
    }
    if(pass===0){
      // At this point no text has been typed, no send was attempted and no
      // active generation or unsent draft is present. Repair only this tab.
      if(!last||!/^https:\/\/chatgpt\.com(?:\/|$)/.test(String(last.url||""))){
        throw Error("No hay compositor visible: ruta ajena a ChatGPT; "+JSON.stringify(last||{}).slice(0,400));
      }
      console.log("BRIDGE VISIBLE COMPOSER RECOVERY :: same-target home navigation, no prompt sent");
      await navigateChatBestEffort(cdp);
      await sleep(delayMs);
    }
  }
  throw Error("No hay compositor visible utilizable tras recuperación aislada; "+JSON.stringify(last||{}).slice(0,450));
}

async function inspectChat(cdp,job){
  const targetName=String(job&&job.target_name||"").trim();
  return cdp.eval("(()=>{const command="+JSON.stringify(commandId)+";const targetName="+JSON.stringify(targetName)+";const root=document.querySelector('main')||document.body;const bodyText=String((document.body&&document.body.innerText)||'');const composer=document.querySelector("+JSON.stringify(COMPOSER_SELECTOR)+");const composerText=String(composer&&(composer.innerText||composer.textContent||composer.value)||'');const composerMarker=composerText.includes(command);const nodes=[...root.querySelectorAll('div,p,span,article,[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"]')].filter(el=>{if(composer&&(el===composer||el.contains(composer)||composer.contains(el)))return false;const t=String(el.innerText||el.textContent||'');return t.includes(command)});const bodyMarker=nodes.length>0;const markerOutsideComposer=bodyMarker;const targetMarker=!!targetName&&bodyText.toLocaleLowerCase().includes(targetName.toLocaleLowerCase());const generating=Boolean(document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]'));const turns=document.querySelectorAll('[data-message-author-role],[data-testid^=\\\"conversation-turn-\\\"],article').length;const largeImages=[...document.images].filter(img=>Number(img.naturalWidth||0)>=640&&Number(img.naturalHeight||0)>=360);const images=largeImages.length;const imageSrc=largeImages.length?String(largeImages[0].currentSrc||largeImages[0].src||''):'';const title=document.title||'';const imageTitle=/Generar imagen IA|Generate image|Image generation/i.test(title);return {hasMarker:markerOutsideComposer,bodyMarker,composerMarker,targetMarker,imageTitle,generating,turns,images,imageSrc,title,url:location.href}})()")
}


async function injectPromptIntoChat(cdp,job){
  // Hydration may expose stale hidden editors; no prompt is typed until one
  // real editor becomes visible. Never reload an active generation or draft.
  await ensureVisibleComposerBeforeInput(cdp);
  const message=buildMessage(job);
  try{
    const before=await domImageCandidates(cdp);
    cdp.preSubmitImageSrcs=new Set(before.map(x=>x.src));
    console.log("BRIDGE SELF-SUBMIT BASELINE images="+before.length);
  }catch{}
  let last={};
  // A visible editor is mandatory: ChatGPT can retain invisible/stale editors
  // in the DOM during SPA navigation. Never type into the first hidden match.
  for(let attempt=1;attempt<=2;attempt++){
    const prep=await cdp.eval("(()=>{const elements=[...document.querySelectorAll("+JSON.stringify(COMPOSER_SELECTOR)+")];const visible=c=>{const r=c.getBoundingClientRect();const style=getComputedStyle(c);return c.isConnected&&!c.disabled&&!c.readOnly&&r.width>12&&r.height>10&&style.display!=='none'&&style.visibility!=='hidden'&&!c.closest('[inert],[aria-hidden=\\\"true\\\"]')};const chosen=elements.find(c=>c.getAttribute('data-tt-image-composer')==='true'&&visible(c))||elements.find(visible);if(!chosen)return {ok:false,found:elements.length,url:location.href};elements.forEach(c=>c.removeAttribute('data-tt-image-composer'));chosen.setAttribute('data-tt-image-composer','true');chosen.focus();try{if(chosen.tagName==='TEXTAREA'||chosen.tagName==='INPUT'){chosen.value='';chosen.dispatchEvent(new Event('input',{bubbles:true}))}else{const s=getSelection(),r=document.createRange();r.selectNodeContents(chosen);s.removeAllRanges();s.addRange(r);document.execCommand('delete',false,null)}}catch(_){}return {ok:true,found:elements.length,tag:chosen.tagName,url:location.href,focused:document.activeElement===chosen}})()");
    if(!prep||!prep.ok){
      // React/Lexical remount between preflight and focus can be transient.
      // There is still no typed prompt or submit at this point.
      if(attempt===1){await sleep(900);continue}
      throw Error("No hay compositor visible tras remount, found="+String(prep&&prep.found||0));
    }
    if(attempt===1){
      try{
        const baseline=await cdp.eval("(()=>({generating:!!document.querySelector('button[data-testid=\\\"stop-button\\\"],button[aria-label*=\\\"Stop\\\" i],button[aria-label*=\\\"Detener\\\" i],button[aria-label*=\\\"Cancelar\\\" i]')}))()");
        cdp.preexistingGenerating=Boolean(baseline&&baseline.generating);
      }catch{cdp.preexistingGenerating=true} // Unknown baseline must not certify a stop-button transition.
    }
    // The previous edit may have caused a React/Lexical rerender; bring the
    // dedicated tab to front and wait for its editor before typing.
    try{await cdp.call("Page.bringToFront",{},5000)}catch{}
    await sleep(attempt===1?250:650);
    const refocus=await cdp.eval("(()=>{const c=document.querySelector('[data-tt-image-composer=\\\"true\\\"]');if(!c||!c.isConnected)return {ok:false};c.focus();return {ok:document.activeElement===c}})()");
    if(!refocus||!refocus.ok){last={...prep,reason:"editor_replaced_during_focus"};continue}
    await cdp.call("Input.insertText",{text:message});
    await sleep(550);
    // Atomic in-page operation: verify the complete CURRENT draft and click
    // Send within ONE CDP Runtime.evaluate. React may remount the editor
    // between separate validation and click calls.
    const atomicSend=await submitVerifiedDraft(cdp,job);
    if(atomicSend){
      cdp.promptWasVerified=true;
      console.log("BRIDGE ATOMIC PROMPT VERIFIED AND SENT attempt="+attempt+" chars="+message.length);
      return cdp;
    }
    const verify=await cdp.eval("(()=>{const c=document.querySelector('[data-tt-image-composer=\\\"true\\\"]');const t=String(c&&(c.value||c.innerText||c.textContent)||'');return {ok:!!c&&t.includes("+JSON.stringify(commandId)+")&&t.includes("+JSON.stringify(message.slice(-65))+")&&t.length>= "+Math.floor(message.length*0.80)+",len:t.length,tag:c&&c.tagName,url:location.href,focused:document.activeElement===c}})()");
    if(verify&&verify.ok){
      cdp.promptWasVerified=true;
      console.log("BRIDGE SELF-SUBMIT PROMPT INJECTED attempt="+attempt+" len="+verify.len);
      return cdp;
    }
    // IMPORTANT: do not press Send on failure. Only clear and retry the draft
    // in the same tab, which prevents posting a partial or duplicate prompt.
    last={...prep,...verify,expectedLength:message.length,reason:"prompt_not_in_visible_editor"};
    console.log("BRIDGE PROMPT RETRY attempt="+attempt+" actual="+String(verify&&verify.len||0)+" expected="+message.length);
  }
  throw Error("Fallback no pudo escribir el prompt completo: "+JSON.stringify(last).slice(0,280));
}


async function submitVerifiedDraft(cdp,job){
  // Only click Send if the CURRENT, complete prompt is still visible
  // in the same dedicated composer. Never send a stale/manual draft.
  const message=buildMessage(job);
  const expression=[
    "(()=>{",
    "const command="+JSON.stringify(commandId)+";",
    "const suffix="+JSON.stringify(message.slice(-65))+";",
    // Important: querySelector(COMPOSER_SELECTOR) returns the first DOM match,
    // even if a hidden/empty editor precedes the marked visible editor.
    // The command text (not DOM order) identifies the editor to submit.
    "const editors=[...document.querySelectorAll("+JSON.stringify(COMPOSER_SELECTOR)+")];",
    "const read=c=>String(c&&(c.value||c.innerText||c.textContent)||'');",
    "const matches=c=>{const t=read(c);return t.includes(command)&&t.includes(suffix)&&t.length>="+Math.floor(message.length*0.8)+"};",
    "const c=editors.find(x=>x.getAttribute('data-tt-image-composer')==='true'&&matches(x))||editors.find(matches);",
    "const txt=read(c);",
    "const maxDraftLength=Math.max(0,...editors.map(x=>read(x).length));",
    "if(!c)return {triggered:false,reason:'draft_missing_or_changed',draftLength:maxDraftLength,editors:editors.length};",
    "const form=c.closest('form');",
    "const sendSelector="+JSON.stringify('button[data-testid="send-button"],button[data-testid="composer-send-button"],button[data-testid="composer-submit-button"],#composer-submit-button,button[aria-label*="Send" i],button[aria-label*="Enviar" i],button[aria-label*="Submit" i],button[type="submit"]')+";",
    "const globalSendSelector="+JSON.stringify('button[data-testid="send-button"],button[data-testid="composer-send-button"],button[data-testid="composer-submit-button"],#composer-submit-button,button[aria-label*="Send" i],button[aria-label*="Enviar" i],button[aria-label*="Submit" i]')+";",
    "const candidates=[...(form?[...form.querySelectorAll(sendSelector)]:[]),...document.querySelectorAll(globalSendSelector)];",
    "const seen=new Set();",
    "const active=b=>{if(!b||seen.has(b))return false;seen.add(b);const r=b.getBoundingClientRect();const v=getComputedStyle(b);return b.isConnected&&!b.disabled&&r.width>1&&r.height>1&&v.display!=='none'&&v.visibility!=='hidden'};",
    "const btn=candidates.find(active);",
    "if(btn){btn.click();return {triggered:true,method:'send-button',url:location.href}};",
    "if(form&&typeof form.requestSubmit==='function'){form.requestSubmit();return {triggered:true,method:'requestSubmit',url:location.href}};",
    "return {triggered:false,reason:'submit_control_unavailable',url:location.href};",
    "})()"
  ].join("");
  let result;
  try{result=await cdp.eval(expression)}catch(e){
    console.log("BRIDGE DIRECT SUBMIT EVAL WARNING "+String(e&&e.message||e).slice(0,120));
    return false;
  }
  if(result&&result.triggered){
    cdp.promptSubmittedAt=Date.now();
    console.log("BRIDGE DIRECT SUBMIT TRIGGERED method="+String(result.method||""));
    return true;
  }
  console.log("BRIDGE DIRECT SUBMIT DEFERRED reason="+String(result&&result.reason||"unknown")+" draftLength="+String(result&&result.draftLength||0));
  return false;
}


async function findFallbackComposerChat(job){
  let list=[];try{list=await targets()}catch{return null}
  const pages=list.filter(x=>x.type==="page"&&String(x.url||"").includes("chatgpt.com")&&x.webSocketDebuggerUrl);
  const ranked=pages.map(t=>{
    const meta=(String(t.title||"")+" "+String(t.url||""));
    const opposite=/TTiTTulares/i.test(meta)&&!/TTendencias/i.test(meta);
    const imageish=/Generar imagen|Gag IA|Image generation|Imagen IA/i.test(meta);
    const projectish=/TTendencias/i.test(meta);
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

// Confirm the CURRENT prompt, not a stale stop button from a previous turn.
// ChatGPT may continue generating on / (temporary chat) or /images without /c/.
// Only a verified, locally triggered send can use a generation transition.
function submissionEvidence(st,{triggeredAt=0,promptWasVerified=false,preexistingGenerating=false,now=Date.now()}={}){
  if(!st)return "";
  if(st.submitted)return "user-turn";
  const elapsed=triggeredAt?now-triggeredAt:0;
  const chatPage=/^https:\/\/chatgpt\.com(?:\/|$)/i.test(String(st.url||""));
  if(!promptWasVerified||!chatPage||elapsed<650||st.composerMarker)return "";
  if(st.commandOutsideComposer)return "command-outside-composer";
  if(st.generating&&!preexistingGenerating)return "post-send-generation";
  return "";
}

async function ensureSubmitted(cdp,job){
  const deadline=Date.now()+45000;
  let current=cdp,last=null,lastAttemptAt=Number(cdp.promptSubmittedAt||0),reacquires=0,triggeredAt=Number(cdp.promptSubmittedAt||0);
  while(Date.now()<deadline){
    let st=null;
    try{
      st=await current.eval("(()=>{const command="+JSON.stringify(commandId)+";const editors=[...document.querySelectorAll("+JSON.stringify(COMPOSER_SELECTOR)+")];const read=c=>String(c&&(c.value||c.innerText||c.textContent)||'');const composer=editors.find(c=>c.getAttribute('data-tt-image-composer')==='true'&&read(c).includes(command))||editors.find(c=>read(c).includes(command))||editors.find(c=>c.getAttribute('data-tt-image-composer')==='true')||editors[0]||null;const composerText=read(composer);const composerMarker=editors.some(c=>read(c).includes(command));const root=document.querySelector('main')||document.body;const bodyText=String((root&&root.innerText)||'');const userTurns=[...root.querySelectorAll('[data-message-author-role=\"user\"],[data-testid*=\"user\" i],[class*=\"user-message\" i]')].filter(el=>String(el.innerText||el.textContent||'').includes(command));const submitted=userTurns.length>0;const generating=Boolean(document.querySelector('button[data-testid=\"stop-button\"],button[aria-label*=\"Stop\" i],button[aria-label*=\"Detener\" i],button[aria-label*=\"Cancelar\" i]'));const send=document.querySelector('button[data-testid=\"send-button\"],button[aria-label*=\"Send\" i],button[aria-label*=\"Enviar\" i],form button[type=\"submit\"]');const inConversation=/\\/c\\//.test(location.pathname);const commandOutsideComposer=bodyText.includes(command)&&!composerMarker;return {composerMarker,submitted,userTurns:userTurns.length,generating,inConversation,commandOutsideComposer,send:!!send,sendDisabled:!!(send&&send.disabled),url:location.href,title:document.title||''}})()");
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
    const evidence=submissionEvidence(st,{
      triggeredAt,promptWasVerified:Boolean(current.promptWasVerified),
      preexistingGenerating:Boolean(current.preexistingGenerating)
    });
    if(evidence){
      current.submissionVerified=true;
      current.acceptInitialRaster=true;
      console.log("BRIDGE SUBMIT VERIFIED mode="+evidence+" generating="+Boolean(st.generating)+" url="+String(st.url||""));
      return current
    }

    if(st&&st.composerMarker&&Date.now()-lastAttemptAt>=6000){
      lastAttemptAt=Date.now();
      const triggered=await submitVerifiedDraft(current,job);
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
    const r=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"progress",upload_secret:secret,worker_id:"ttendencias-image-bridge-v34-sites-return",phase:String(phase||"pc_progress"),detail:String(detail||"").slice(0,220)});
    if(!r.ok)console.log("BRIDGE PROGRESS ACK WARNING "+String(phase)+" "+r.status+" "+String(r.data&&r.data.error||""))
  }catch(e){console.log("BRIDGE PROGRESS WARNING "+String(phase)+" :: "+String(e&&e.message||e))}
}
async function fail(reason){
  try{await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"failed",worker_id:"ttendencias-image-bridge-v34-sites-return",upload_secret:secret,reason:String(reason||"").slice(0,220)})}catch{}
}
// The prompt must be confirmed in GitHub before claiming launch success.
// Retrying an ACK never resubmits the prompt or opens a second chat.
async function confirmPromptLaunched(){
  let last="sin ACK";
  for(let attempt=1;attempt<=5;attempt++){
    try{
      const r=await post({task:"image_pc_ack",target_id:targetId,
        command_id:commandId,stage:"launched",
        worker_id:"ttendencias-image-bridge-v34-sites-return"});
      if(r.ok&&r.data&&r.data.pc_launched_at&&!r.data.deferred){
        console.log("BRIDGE IMAGE LAUNCH CONFIRMED "+r.data.pc_launched_at);
        return true;
      }
      last="HTTP "+r.status+" deferred="+Boolean(r.data&&r.data.deferred)+" error="+String(r.data&&r.data.error||"");
      if(r.status===409&&String(r.data&&r.data.error||"").includes("command_id"))throw Error("job_superado");
    }catch(e){
      last=String(e&&e.message||e);
      if(last==="job_superado")throw e;
    }
    await sleep(attempt*1200);
    try{
      const job=await fetchJob();
      if(job.pc_launched_at&&String(job.command_id)===commandId){
        console.log("BRIDGE IMAGE LAUNCH CONFIRMED VIA JOB "+job.pc_launched_at);
        return true;
      }
    }catch{}
  }
  throw Error("image_launch_ack_not_persisted "+last)
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
// After LAUNCHED, protect only this already-submitted conversation long enough
// for the independent read-only publisher to receive the raster. Never request
// another generation, navigate away, or touch the other project's fixed tab.
async function holdForWebImageReceipt(maxMs=240000,pollMs=15000){
  const deadline=Date.now()+maxMs;
  while(Date.now()<deadline){
    await sleep(Math.min(pollMs,Math.max(1,deadline-Date.now())));
    let current;
    try{current=await fetchJob();}catch{continue}
    if(String(current.command_id||"")!==commandId)return "superseded";
    const status=String(current.status||"").toUpperCase();
    if(status==="DONE"&&current.upload_sha256)return "web_image_done";
    if(String(current.web_image?.stage||"")==="published")return "web_image_published";
    if(status==="CANCELLED"||status==="SUPERSEDED")return "cancelled";
  }
  return "receipt_not_confirmed_within_hold";
}
// Optional delivery bookkeeping. Failure here is never a generation failure.
// Keep this boundary separate from the pre-submit and launched receipts.
async function optionalWebHandoff(handoff,remember=false){
  try{
    const exporter=require("./TTendenciasWebImages.cjs");
    if(remember&&await exporter.rememberConversation(handoff)===false)return false;
    if(!remember)exporter.enroll(handoff);
    console.log("TTENDENCIAS WEB IMAGE REGISTERED target="+handoff.targetId);
    return true;
  }catch(e){
    console.log("TTENDENCIAS WEB IMAGE REGISTRATION DEFERRED target="+handoff.targetId+" reason="+String(e&&e.message||e).slice(0,160));
    return false;
  }
}
(async()=>{
  let cdp;
  let webHandoff;
  try{
    console.log("BRIDGE START "+commandId);
    const job=await fetchJob();
    const launchOnly=String(job.delivery_mode||"")==="launch_only";
    // Safety invariant: this bridge may submit prompts only, never capture,
    // download, rasterize, upload, or forward generated images.
    if(!launchOnly)throw Error("legacy_raster_mode_disabled_request_launch_only_job");
    // Only this boundary is provably before typing or submitting this job.
    try{cdp=await openFreshDedicatedConversation();}
    catch(e){throw Error("TTENDENCIAS_PRE_SUBMIT_FAILED "+String(e&&e.message||e));}
    console.log("BRIDGE FIXED CHAT READY mode="+BRIDGE_MODE);
    webHandoff={job,commandId,targetId,browserTargetId:cdp.fixedTargetId,secret};
    let image=null;
    for(let generationAttempt=1;generationAttempt<=2;generationAttempt++){
      if(generationAttempt>1){
        try{cdp&&cdp.close()}catch{}
        await progress("image_retry","Primer envío no produjo generación real; reintentando en conversación nueva de la misma pestaña.");
        cdp=await openFreshDedicatedConversation();
        console.log("BRIDGE INTERNAL RETRY conversation="+generationAttempt);
      }
      cdp=await injectPromptIntoChat(cdp,job);
      if(!cdp.promptSubmittedAt)await submitVerifiedDraft(cdp,job);
      cdp=await ensureSubmitted(cdp,job);
      cdp.acceptInitialRaster=true;
      console.log("BRIDGE FIXED PROMPT SUBMITTED/VERIFIED attempt="+generationAttempt);
      if(generationAttempt===1){
        if(!launchOnly)await progress("prompt_sent","Prompt GAG IA enviado y verificado en conversación nueva de la pestaña fija.");
        await confirmPromptLaunched();
      }
      if(launchOnly){
        // Generation is already acknowledged. Resolve only the URL whose
        // last user turn proves this command; never save a guessed location.
        for(let n=0;n<5;n++){
          if(await optionalWebHandoff(webHandoff,true))break;
          await sleep(700);
        }
        // The relay may no longer be installed. The publisher can read this
        // same existing 9223 conversation without opening a new Chrome tab,
        // provided the producer does not immediately reuse it for the next job.
        const receipt=await holdForWebImageReceipt();
        console.log("TTENDENCIAS LAUNCH_ONLY CONFIRMED receipt="+receipt+"; bridge sin captura ni subida");
        return;
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
      const done=await post({task:"image_pc_ack",target_id:targetId,command_id:commandId,stage:"done",worker_id:"ttendencias-image-bridge-v29-raw-job-recovery",upload_secret:secret});
      if(done.ok){console.log("BRIDGE DONE");return}
      if(done.status!==409||!done.data||done.data.error!=="image_not_persisted_yet")throw Error("Finalize "+done.status+": "+(done.data&&done.data.error||"sin detalle"))
    }
    throw Error("Outbox recibido pero no materializado en 6 minutos");
  }catch(e){
    console.error("BRIDGE ERROR :: "+String(e&&e.message||e));
    await fail(e&&e.message||e);
    process.exitCode=1;
  }finally{
    if(webHandoff)await optionalWebHandoff(webHandoff,true);
    try{cdp&&cdp.close()}catch{}
  }
})();
