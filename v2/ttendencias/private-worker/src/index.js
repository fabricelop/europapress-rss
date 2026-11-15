// TTActualidad V2, private single-password frontend.
// NO V1 changes. Signed sessions; V2 D1 stores red marks and 15-minute radar.
import {captureRadar,loadRadar,mergeEditorialRadar,radarAgeMinutes} from "./radar.js";
// All static assets require a session because run_worker_first=true.
const COOKIE = "__Host-ttv2";
const SESSION_VERSION = "v1";
const HOUR = 3600000;
const MAX_SESSION_HOURS = 30 * 24;
const SOURCE = "https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/state/";
const ALLOWED = new Set(["web-top30.json", "listas.json"]);
const encoder = new TextEncoder();

function headers(extra = {}) {
  return {
    "Cache-Control": "no-store, private, max-age=0",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Resource-Policy": "same-origin",
    ...extra
  };
}
function result(text, status=200, extra={}) {
  return new Response(text, { status, headers: headers(extra) });
}
function json(data, status=200, extra={}) {
  return result(JSON.stringify(data), status, {"Content-Type":"application/json; charset=utf-8", ...extra});
}
function parseCookies(request) {
  const raw = request.headers.get("cookie") || "";
  for (const entry of raw.split(";")) {
    const [name, ...value] = entry.trim().split("=");
    if (name === COOKIE) return value.join("=");
  }
  return "";
}
function safeEqual(a,b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const aa = encoder.encode(a), bb = encoder.encode(b);
  let diff = aa.length ^ bb.length;
  for (let i = 0; i < Math.max(aa.length,bb.length); i++) diff |= (aa[i] || 0) ^ (bb[i] || 0);
  return diff === 0;
}
function b64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
}
async function sha256(value) {
  return b64(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}
async function signature(data,secret) {
  const key = await crypto.subtle.importKey("raw",encoder.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  return b64(await crypto.subtle.sign("HMAC",key,encoder.encode(data)));
}
function configured(env) {
  return typeof env.AUTH_PASSWORD === "string" && env.AUTH_PASSWORD.length >= 16
    && typeof env.SESSION_SECRET === "string" && env.SESSION_SECRET.length >= 32;
}
function duration(env) {
  const hours = Number(env.SESSION_HOURS);
  return (Number.isFinite(hours) && hours >= 1 && hours <= MAX_SESSION_HOURS ? hours : 12) * HOUR;
}
async function newSession(env) {
  const expires = Date.now() + duration(env);
  const nonce = b64(crypto.getRandomValues(new Uint8Array(16)));
  const data = [SESSION_VERSION,expires,nonce].join(".");
  return data + "." + await signature(data, env.SESSION_SECRET);
}
async function isAuthorized(request,env) {
  if (!configured(env)) return false;
  const parts = parseCookies(request).split(".");
  if (parts.length !== 4 || parts[0] !== SESSION_VERSION) return false;
  const expires = Number(parts[1]);
  if (!Number.isSafeInteger(expires) || expires <= Date.now()
      || expires > Date.now() + MAX_SESSION_HOURS * HOUR) return false;
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(parts[2])) return false;
  const data = parts.slice(0,3).join(".");
  return safeEqual(await signature(data,env.SESSION_SECRET),parts[3]);
}
function sameOrigin(request) {
  const origin = request.headers.get("origin");
  return origin === new URL(request.url).origin
    && request.headers.get("x-ttv2-action") === "1";
}

const TREND_ID = /^trv2-[a-f0-9]{24}$/;
function entryStamp(item) {return typeof item?.entered_top30_at==="string" ? item.entered_top30_at : "";}
const RE_DISPLAYED = new Set(["captured_review","ready","published"]);
const RE_PROCESSING = new Set(["review_pending","in_progress","capture_recovery"]);
// La imagen original permanece en GitHub: su ocultación es reversible y
// compartida mediante un indicador mínimo consultable desde el site público.
async function imageSuppressionsTable(db) {
  await db.prepare("CREATE TABLE IF NOT EXISTS image_suppressions (trend_id TEXT NOT NULL, revision INTEGER NOT NULL, suppressed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), PRIMARY KEY(trend_id,revision))").run();
  await db.prepare("CREATE TABLE IF NOT EXISTS public_image_prefs (trend_id TEXT NOT NULL, revision INTEGER NOT NULL, visible INTEGER NOT NULL CHECK(visible IN (0,1)), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), PRIMARY KEY(trend_id,revision))").run();
}
// Una cautela inicial para temas de especial sensibilidad. No pretende
// sustituir la revisión editorial ni inspecciona el contenido visual.
function sensitiveEditorial(item) {
  const words=String((item?.name||"")+" "+(item?.explanation||""))
    .normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase();
  return /\b(?:asesinat\w*|fallec\w*|muert\w*|suicid\w*|violacion\w*|abuso\s+sexual|agresion\s+sexual|menores?\s+de\s+edad|ninos?\s+(?:herid\w*|fallecid\w*|victim\w*)|atentad\w*|bombarde\w*|secuestro\w*|tortur\w*|cadaver\w*|victimas?\s+mortal\w*|catastrofe\w*|tragedia\w*|naufragio\w*|sangre|herid\w*\s+grave\w*)\b/u.test(words);
}
async function reXTable(db) {
  await db.prepare("CREATE TABLE IF NOT EXISTS re_x_context (trend_id TEXT NOT NULL, base_revision INTEGER NOT NULL, hints TEXT NOT NULL, PRIMARY KEY(trend_id,base_revision))").run();
}
async function publicEditorialOverrides(env) {
  if (!env.MARKS_DB) throw Error("OVERRIDES_STORAGE_UNAVAILABLE");
  await imageSuppressionsTable(env.MARKS_DB);
  await reXTable(env.MARKS_DB);
  const [pending,images,preferences,contexts]=await Promise.all([
    env.MARKS_DB.prepare("SELECT trend_id,base_revision FROM re_requests WHERE status IN ('requested','applied') ORDER BY requested_at DESC LIMIT 200").all(),
    env.MARKS_DB.prepare("SELECT trend_id,revision FROM image_suppressions ORDER BY suppressed_at DESC LIMIT 200").all(),
    env.MARKS_DB.prepare("SELECT trend_id,revision,visible FROM public_image_prefs ORDER BY updated_at DESC LIMIT 200").all(),
    env.MARKS_DB.prepare("SELECT trend_id,base_revision,hints FROM re_x_context LIMIT 200").all()
  ]);
  const notes=new Map((contexts.results||[]).filter(x=>TREND_ID.test(x.trend_id)&&Number.isSafeInteger(x.base_revision)&&typeof x.hints==="string"&&x.hints.length<=1200).map(x=>[x.trend_id+":"+x.base_revision,x.hints]));
  const re=(pending.results||[]).filter(x=>TREND_ID.test(x.trend_id)&&Number.isSafeInteger(x.base_revision)&&x.base_revision>0).map(x=>{
    const hints=notes.get(x.trend_id+":"+x.base_revision);
    return hints?{...x,mode:"x",hints}:{...x,mode:"standard"};
  });
  const suppressed=(images.results||[]).filter(x=>TREND_ID.test(x.trend_id)&&Number.isSafeInteger(x.revision)&&x.revision>0);
  const visibility=(preferences.results||[]).filter(x=>TREND_ID.test(x.trend_id)&&Number.isSafeInteger(x.revision)&&x.revision>0&&(x.visible===0||x.visible===1));
  return {re,suppressed,visibility};
}
async function imageVisibility(request,env) {
  if (!env.MARKS_DB)return json({error:"image_storage_not_configured"},503);
  if (request.method!=="POST"||!sameOrigin(request))return json({error:"method_not_allowed"},405);
  if(Number(request.headers.get("content-length")||0)>1024)return json({error:"invalid_payload"},413);
  let body;
  try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
  const {trend_id,revision,scope,hidden,visible}=body||{};
  if(!TREND_ID.test(trend_id)||!Number.isSafeInteger(revision)||revision<1||revision>100000||
     !((scope==="both"&&typeof hidden==="boolean")||(scope==="public"&&typeof visible==="boolean")))
    return json({error:"invalid_payload"},400);
  try{
    const ranking=await currentRanking(env);
    const current=ranking.find(x=>x.trend_id===trend_id);
    if(!current||current.revision!==revision||current.status!=="explicada"||current.re_in_progress===true)
      return json({error:"trend_not_current"},409);
    await imageSuppressionsTable(env.MARKS_DB);
    if(scope==="both"){
      if(hidden)
        await env.MARKS_DB.prepare("INSERT INTO image_suppressions(trend_id,revision) VALUES(?,?) ON CONFLICT(trend_id,revision) DO NOTHING").bind(trend_id,revision).run();
      else
        await env.MARKS_DB.prepare("DELETE FROM image_suppressions WHERE trend_id=? AND revision=?").bind(trend_id,revision).run();
    }else{
      await env.MARKS_DB.prepare("INSERT INTO public_image_prefs(trend_id,revision,visible) VALUES(?,?,?) ON CONFLICT(trend_id,revision) DO UPDATE SET visible=excluded.visible,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')").bind(trend_id,revision,visible?1:0).run();
    }
    return json({ok:true,trend_id,revision,scope,hidden:scope==="both"?hidden:undefined,visible:scope==="public"?visible:undefined});
  }catch{return json({error:"image_visibility_unavailable"},503);}
}
async function currentRanking(env) {
  const upstream=await fetch(SOURCE+"web-top30.json",{headers:{"Accept":"application/json"},cf:{cacheTtl:15,cacheEverything:true}});
  if(!upstream.ok) throw Error("RANKING_UNAVAILABLE");
  const data=await upstream.json();
  if(data?.project!=="ttactualidad-v2" || !Array.isArray(data.items) || data.items.length!==data.count || data.items.length>40) throw Error("RANKING_INVALID");
  // The Cloudflare cron is the authoritative ranking for the private website.
  // Editorial explanations still come from the separate, read-only GitHub V2 ledger.
  let live=null;
  try{live=await loadRadar(env?.MARKS_DB);}catch(error){console.warn("TT_V2_RADAR_READ_FALLBACK",String(error));}
  return (await mergeEditorialRadar(data,live)).items;
}
async function redMarks(request,env) {
  if(!env.MARKS_DB) return json({error:"marks_storage_not_configured"},503);
  if(request.method!=="GET" && (request.method!=="POST" || !sameOrigin(request))) return json({error:"method_not_allowed"},405);
  try {
    const rows=(await env.MARKS_DB.prepare("SELECT trend_id, entered_top30_at FROM red_marks").all()).results || [];
    // Cloudflare/GitHub capturan en momentos distintos y pueden discrepar sobre
    // entered_top30_at. Consultar NUNCA debe borrar una preferencia del usuario.
    // La marca pertenece al ID estable hasta que el usuario la quite con R.
    const valid=new Map(rows.filter(row=>TREND_ID.test(row.trend_id)).map(row=>[row.trend_id,row.entered_top30_at]));
    if(request.method==="GET") return json({marks:Object.fromEntries(valid),captured_at:new Date().toISOString()});
    if(Number(request.headers.get("content-length")||0)>1024) return json({error:"invalid_payload"},413);
    let body;
    try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
    if(!body || typeof body!=="object" || !TREND_ID.test(body.trend_id) || typeof body.entered_top30_at!=="string" || typeof body.marked!=="boolean") return json({error:"invalid_payload"},400);
    // El usuario puede estar viendo un Top30 anterior al último refresco. La R
    // se vincula al ID estable, incluso si la tendencia acaba de salir.
    const timestamp=Date.parse(body.entered_top30_at);
    if(body.entered_top30_at.length>64 || !Number.isFinite(timestamp) || timestamp>Date.now()+3600000)
      return json({error:"invalid_entry_stamp"},400);
    const stamp=body.entered_top30_at;
    if(body.marked) await env.MARKS_DB.prepare("INSERT INTO red_marks (trend_id, entered_top30_at) VALUES (?,?) ON CONFLICT(trend_id) DO UPDATE SET entered_top30_at=excluded.entered_top30_at").bind(body.trend_id,stamp).run();
    else await env.MARKS_DB.prepare("DELETE FROM red_marks WHERE trend_id=?").bind(body.trend_id).run();
    return json({ok:true,trend_id:body.trend_id,marked:body.marked});
  }catch{return json({error:"marks_storage_unavailable"},503);}
}

async function reRequests(request,env) {
  if(!env.MARKS_DB)return json({error:"re_storage_not_configured"},503);
  if(request.method!=="GET" && (request.method!=="POST" || !sameOrigin(request)))
    return json({error:"method_not_allowed"},405);
  try {
    if(request.method==="GET") {
      const rows=(await env.MARKS_DB.prepare(
        "SELECT trend_id, base_revision, status FROM re_requests WHERE status IN ('requested','applied') ORDER BY requested_at DESC LIMIT 100").all()).results||[];
      return json({requests:rows});
    }
    if(Number(request.headers.get("content-length")||0)>1024)return json({error:"invalid_payload"},413);
    let body;
    try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
    const {trend_id,revision,entered_top30_at}=body||{};
    const mode=body?.mode===undefined?"standard":body.mode;
    const hints=mode==="x"&&typeof body?.hints==="string"?body.hints.trim():"";
    if((mode!=="standard"&&mode!=="x")||(mode==="x"&&(hints.length<10||hints.length>1200))||
       (mode==="standard"&&body?.hints!==undefined)||
       !TREND_ID.test(trend_id)||!Number.isSafeInteger(revision)||revision<1||revision>100000||
       typeof entered_top30_at!=="string"||entered_top30_at.length>64)
      return json({error:"invalid_payload"},400);
    let ranking;
    try{ranking=await currentRanking(env);}catch{return json({error:"ranking_unavailable"},503);}
    const current=ranking.find(x=>x.trend_id===trend_id);
    if(!current||current.revision!==revision||
       current.status!=="explicada")return json({error:"trend_not_current"},409);
    if(current.re_in_progress===true)return json({error:"re_already_processing"},409);
    if(mode==="x"){
      await reXTable(env.MARKS_DB);
      await env.MARKS_DB.prepare("INSERT INTO re_x_context(trend_id,base_revision,hints) VALUES(?,?,?) ON CONFLICT(trend_id,base_revision) DO UPDATE SET hints=excluded.hints").bind(trend_id,revision,hints).run();
    }
    await env.MARKS_DB.prepare(
      "INSERT INTO re_requests (trend_id, base_revision, entered_top30_at, status) VALUES (?,?,?,'requested') " +
      "ON CONFLICT(trend_id,base_revision) DO NOTHING"
    ).bind(trend_id,revision,entered_top30_at).run();
    return json({ok:true,queued:true,trend_id,base_revision:revision,mode},202);
  }catch{return json({error:"re_storage_unavailable"},503);}
}


const HEX64=/^[a-f0-9]{64}$/;
const IMAGE_COMMAND=/^v2-img-trv2-[a-f0-9]{24}-r[1-9][0-9]*-a[1-9][0-9]*-[a-zA-Z0-9_-]{8,60}$/;
const IMAGE_TYPES={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"};
async function imageRead(request,env,trendId) {
  // Same as V1: original raster lives on the isolated GitHub branch.
  // This endpoint requires the existing private site session.
  if(request.method!=="GET"||!TREND_ID.test(trendId))return json({error:"not_found"},404);
  const revision=Number(new URL(request.url).searchParams.get("revision"));
  if(!Number.isSafeInteger(revision)||revision<1||revision>100000)return json({error:"revision_invalid"},400);
  try {
    if(env.MARKS_DB){
      const flags=await publicEditorialOverrides(env);
      if(flags.suppressed.some(row=>row.trend_id===trendId&&row.revision===revision)||
         flags.re.some(row=>row.trend_id===trendId&&row.base_revision===revision))
        return json({error:"image_hidden"},404);
    }
    const response=await fetch(SOURCE+"editorial-queue.json",{
      headers:{"Accept":"application/json"},cf:{cacheTtl:5,cacheEverything:true}});
    if(!response.ok)return json({error:"editorial_unavailable"},502);
    const queue=await response.json();
    if(queue?.step!=="04_editorial_queue"||queue.effects_enabled!==false)
      return json({error:"editorial_not_isolated"},503);
    const row=queue.items?.[trendId];
    const previous=RE_PROCESSING.has(row?.status)&&row?.previous_revision===revision&&
      row?.revision===revision+1&&RE_DISPLAYED.has(row?.previous_status);
    const cap=previous?(row.previous_capture||{}):(row?.capture||{});
    const img=cap.image||{};
    if(row?.trend_id!==trendId||(!previous&&row?.revision!==revision)||
       !(previous||RE_DISPLAYED.has(row.status))||
       cap.revision!==revision||img.status!=="saved"||
       img.revision!==revision||img.backend!=="github_v1_style"||
       !HEX64.test(img.sha256||"")||!IMAGE_COMMAND.test(img.command_id||""))
       return json({error:"image_not_ready"},404);
    const ext=IMAGE_TYPES[img.mime];
    const expected="v2/ttendencias/generated-images/"+trendId+"-r"+revision+
                   "-"+img.sha256.slice(0,24)+"."+ext;
    if(!ext||img.path!==expected)
      return json({error:"image_identity_invalid"},409);
    const raw="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+
      "feature/ttactualidad-v2-clean/"+expected;
    const original=await fetch(raw,{headers:{"Accept":img.mime},cf:{cacheTtl:30,cacheEverything:true}});
    if(!original.ok)return json({error:"image_missing"},404);
    const buffer=await original.arrayBuffer();
    if(buffer.byteLength<100000||buffer.byteLength>8388608||
       await sha256Bytes(buffer)!==img.sha256)
      return json({error:"image_integrity_invalid"},502);
    const first=new Uint8Array(buffer.slice(0,16));
    const png=first.slice(0,8).every((v,i)=>v===[137,80,78,71,13,10,26,10][i]);
    const jpg=first[0]===255&&first[1]===216&&first[2]===255;
    const webp=String.fromCharCode(...first.slice(0,4))==="RIFF"&&
               String.fromCharCode(...first.slice(8,12))==="WEBP";
    if(!({"image/png":png,"image/jpeg":jpg,"image/webp":webp})[img.mime])
      return json({error:"image_format_invalid"},502);
    return new Response(buffer,{headers:headers({
      "Content-Type":img.mime,"ETag":'"'+img.sha256+'"',
      "Content-Disposition":"inline"})});
  } catch {
    return json({error:"image_read_unavailable"},503);
  }
}
async function sha256Bytes(bytes){return [...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(b=>b.toString(16).padStart(2,"0")).join("");}

const LOGIN = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow"><meta name="color-scheme" content="dark"><title>TTActualidad V2 · Acceso privado</title><style>body{background:#090b0f;color:#f2f5fa;min-height:100vh;display:grid;place-items:center;font:16px system-ui;margin:0}main{padding:32px;width:min(380px,90vw);background:#171c26;border:1px solid #354052;border-radius:16px}h1{font-size:22px}input,button{font:inherit;padding:13px;border-radius:9px;width:100%;box-sizing:border-box;margin-top:10px}input{background:#0c111c;color:white;border:1px solid #667187}button{background:#e25d44;color:white;font-weight:700;border:0;cursor:pointer}p{color:#a6b4c7}#msg{color:#ffaaaa}</style></head><body><main><h1>TTActualidad V2</h1><p>Acceso privado</p><form id="f"><label for="p">Contraseña</label><input id="p" type="password" minlength="16" autocomplete="current-password" required autofocus><button type="submit">Entrar</button><p id="msg" role="status"></p></form></main><script>document.getElementById("f").addEventListener("submit",async e=>{e.preventDefault();const b=e.target.querySelector("button");b.disabled=true;try{const r=await fetch("/api/login",{method:"POST",headers:{"content-type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({password:document.getElementById("p").value}),credentials:"same-origin"});document.getElementById("p").value="";if(!r.ok){document.getElementById("msg").textContent="Contraseña incorrecta o acceso no configurado.";return}location.replace("/")}catch{document.getElementById("msg").textContent="No se pudo iniciar sesión."}finally{b.disabled=false}})</script></body></html>`;
export default {
  async scheduled(controller,env,ctx) {
    // Cloudflare Cron Trigger: exactly one scheduled attempt every 15 minutes.
    // A failed third-party read must fail visibly in Cron Events rather than
    // writing a misleading fresh timestamp.
    await captureRadar(env.MARKS_DB);
  },
  async fetch(request,env,ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ok:true,service:"ttactualidad-v2-private",configured:configured(env),image_storage:"github",image_flow:"same-chat",build:"v2-same-chat-github-20261114"});
    // Única ruta pública adicional: devuelve identificadores y revisiones,
    // nunca contraseñas, marcas privadas, explicaciones ni imágenes.
    if (url.pathname === "/api/public-editorial-overrides") {
      if(request.method!=="GET")return json({error:"method_not_allowed"},405);
      try{return json({schema_version:1,...await publicEditorialOverrides(env)});}
      catch{return json({error:"editorial_overrides_unavailable"},503);}
    }
    if (!configured(env)) return result("Acceso privado no configurado",503);
    if (url.pathname === "/api/image-ingest-ready" || url.pathname === "/api/image-ingest") return json({error:"image_backend_migrated_to_github"},410);
    if (url.pathname === "/api/login") {
      if (request.method !== "POST" || !sameOrigin(request)) return json({ok:false},403);
      // Five approximate login attempts per minute per network origin, no KV writes.
      // The counter is local to a Cloudflare location, not a global strict lock.
      if (env.LOGIN_LIMITER) {
        const ip=request.headers.get("cf-connecting-ip") || "missing-ip";
        const verdict=await env.LOGIN_LIMITER.limit({key:"ttv2-login:"+ip});
        if (!verdict.success) return json({ok:false,error:"too_many_attempts"},429,{"Retry-After":"60"});
      }
      if (Number(request.headers.get("content-length") || 0) > 2048) return json({ok:false},413);
      let password = "";
      try {const obj=await request.json();password=typeof obj.password==="string" ? obj.password : "";}catch{}
      if (password.length < 16 || password.length > 256
          || !safeEqual(await sha256(password),await sha256(env.AUTH_PASSWORD))) return json({ok:false},401);
      const token=await newSession(env);
      return json({ok:true},200,{"Set-Cookie":COOKIE+"="+token+"; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age="+Math.floor(duration(env)/1000)});
    }
    const authorized = await isAuthorized(request,env);
    if (url.pathname === "/api/logout") {
      if (!authorized || request.method !== "POST" || !sameOrigin(request)) return json({ok:false},403);
      return json({ok:true},200,{"Set-Cookie":COOKIE+"=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"});
    }
    if (!authorized) {
      if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html"))
        return result(LOGIN,200,{"Content-Type":"text/html; charset=utf-8","Content-Security-Policy":"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"});
      return json({error:"unauthorized"},401);
    }
    if (url.pathname === "/api/me") return json({authenticated:true});
    if (url.pathname.startsWith("/api/image/")) return imageRead(request,env,url.pathname.slice("/api/image/".length));
    if (url.pathname === "/api/image-visibility")return imageVisibility(request,env);
    if (url.pathname === "/api/marks") return redMarks(request,env);
    if (url.pathname === "/api/re-explain") return reRequests(request,env);
    if (url.pathname.startsWith("/api/state/")) {
      if (request.method !== "GET") return json({error:"method_not_allowed"},405);
      const name = url.pathname.slice("/api/state/".length);
      if (!ALLOWED.has(name)) return json({error:"not_found"},404);
      const upstream=await fetch(SOURCE+name,{headers:{"Accept":"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
      if (!upstream.ok) return json({error:"source_unavailable"},502);
      const body=await upstream.text();
      if (body.length>2000000) return json({error:"oversized_source"},502);
      if(name==="web-top30.json"){
        let live=null;
        try{live=await loadRadar(env.MARKS_DB);}catch(error){console.warn("TT_V2_RADAR_NOT_READY",String(error));}
        const raw=JSON.parse(body);
        const view=await mergeEditorialRadar(raw,live);
        // Aplicar el mismo bloqueo que verá V1 incluso si GitHub aún no ha
        // procesado la solicitud RE. Así no reaparecen imágenes antiguas.
        try{
          const flags=await publicEditorialOverrides(env);
          for(const row of view.items){
            const preference=flags.visibility.find(x=>x.trend_id===row.trend_id&&x.revision===row.revision);
            row.public_image_visible=preference?preference.visible===1:!sensitiveEditorial(row);
            row.image_sensitivity_default=sensitiveEditorial(row);
            if(flags.re.some(x=>x.trend_id===row.trend_id&&x.base_revision===row.revision)){
              row.re_in_progress=true;row.image_available=false;row.explanation="";
            }
            if(flags.suppressed.some(x=>x.trend_id===row.trend_id&&x.revision===row.revision)){
              row.image_suppressed=true;row.image_available=false;
            }
          }
        }catch(error){console.warn("TT_V2_IMAGE_FLAGS_UNAVAILABLE",String(error));}
        if(!live) {
          view.radar_source="github_fallback";
          const age=(Date.now()-Date.parse(raw.captured_at))/60000;
          if(age>25)view.radar_warning="Radar desactualizado: Cloudflare todavía no ha guardado su primera captura programada.";
        }
        if(live&&radarAgeMinutes(live)>22&&ctx?.waitUntil){
          // Recovery only if the previous full 15m window has been missed.
          // No extra scheduled executions and no dependency on Windows.
          ctx.waitUntil(captureRadar(env.MARKS_DB).catch(e=>console.error("TT_V2_RADAR_RECOVERY_FAILED",String(e))));
        }
        return json(view);
      }
      return result(body,200,{"Content-Type":"application/json; charset=utf-8"});
    }
    if (url.pathname.startsWith("/api/")) return json({error:"action_not_enabled"},503);
    if (request.method !== "GET" && request.method !== "HEAD") return json({error:"method_not_allowed"},405);
    const response=await env.ASSETS.fetch(request);
    const h=new Headers(response.headers);
    Object.entries(headers()).forEach(([key,value])=>h.set(key,value));
    h.set("Content-Security-Policy","default-src 'self'; img-src 'self' data:; connect-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'");
    return new Response(response.body,{status:response.status,headers:h});
  }
};
