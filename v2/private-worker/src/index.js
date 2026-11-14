// TTActualidad V2, private single-password frontend.
// NO V1 changes. Stateless signed sessions; zero KV/D1 operations per visit.
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
async function currentRanking() {
  const upstream=await fetch(SOURCE+"web-top30.json",{headers:{"Accept":"application/json"},cf:{cacheTtl:15,cacheEverything:true}});
  if(!upstream.ok) throw Error("RANKING_UNAVAILABLE");
  const data=await upstream.json();
  if(data?.project!=="ttactualidad-v2" || !Array.isArray(data.items) || data.items.length!==data.count || data.items.length>40) throw Error("RANKING_INVALID");
  return data.items;
}
async function redMarks(request,env) {
  if(!env.MARKS_DB) return json({error:"marks_storage_not_configured"},503);
  if(request.method!=="GET" && (request.method!=="POST" || !sameOrigin(request))) return json({error:"method_not_allowed"},405);
  let ranking;
  try { ranking=await currentRanking(); } catch {return json({error:"ranking_temporarily_unavailable"},503);}
  const active=new Map(ranking.filter(row=>TREND_ID.test(row.trend_id) && entryStamp(row)).map(row=>[row.trend_id,entryStamp(row)]));
  try {
    const rows=(await env.MARKS_DB.prepare("SELECT trend_id, entered_top30_at FROM red_marks").all()).results || [];
    const valid=new Map(), stale=[];
    for(const row of rows) {
      if(active.get(row.trend_id)===row.entered_top30_at) valid.set(row.trend_id,row.entered_top30_at);
      else stale.push(row.trend_id);
    }
    // Every GET reconciles against the authoritative current Top30, not a browser-local cache.
    for(const id of stale) await env.MARKS_DB.prepare("DELETE FROM red_marks WHERE trend_id = ?").bind(id).run();
    if(request.method==="GET") return json({marks:Object.fromEntries(valid),captured_at:new Date().toISOString()});
    if(Number(request.headers.get("content-length")||0)>1024) return json({error:"invalid_payload"},413);
    let body;
    try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
    if(!body || typeof body!=="object" || !TREND_ID.test(body.trend_id) || typeof body.entered_top30_at!=="string" || typeof body.marked!=="boolean") return json({error:"invalid_payload"},400);
    const stamp=active.get(body.trend_id);
    if(!stamp || stamp!==body.entered_top30_at) return json({error:"trend_not_current"},409);
    if(body.marked) await env.MARKS_DB.prepare("INSERT INTO red_marks (trend_id, entered_top30_at) VALUES (?,?) ON CONFLICT(trend_id) DO UPDATE SET entered_top30_at=excluded.entered_top30_at").bind(body.trend_id,stamp).run();
    else await env.MARKS_DB.prepare("DELETE FROM red_marks WHERE trend_id=?").bind(body.trend_id).run();
    return json({ok:true,trend_id:body.trend_id,marked:body.marked});
  }catch{return json({error:"marks_storage_unavailable"},503);}
}

const LOGIN = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow"><meta name="color-scheme" content="dark"><title>TTActualidad V2 · Acceso privado</title><style>body{background:#090b0f;color:#f2f5fa;min-height:100vh;display:grid;place-items:center;font:16px system-ui;margin:0}main{padding:32px;width:min(380px,90vw);background:#171c26;border:1px solid #354052;border-radius:16px}h1{font-size:22px}input,button{font:inherit;padding:13px;border-radius:9px;width:100%;box-sizing:border-box;margin-top:10px}input{background:#0c111c;color:white;border:1px solid #667187}button{background:#e25d44;color:white;font-weight:700;border:0;cursor:pointer}p{color:#a6b4c7}#msg{color:#ffaaaa}</style></head><body><main><h1>TTActualidad V2</h1><p>Acceso privado</p><form id="f"><label for="p">Contraseña</label><input id="p" type="password" minlength="16" autocomplete="current-password" required autofocus><button type="submit">Entrar</button><p id="msg" role="status"></p></form></main><script>document.getElementById("f").addEventListener("submit",async e=>{e.preventDefault();const b=e.target.querySelector("button");b.disabled=true;try{const r=await fetch("/api/login",{method:"POST",headers:{"content-type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({password:document.getElementById("p").value}),credentials:"same-origin"});document.getElementById("p").value="";if(!r.ok){document.getElementById("msg").textContent="Contraseña incorrecta o acceso no configurado.";return}location.replace("/")}catch{document.getElementById("msg").textContent="No se pudo iniciar sesión."}finally{b.disabled=false}})</script></body></html>`;
export default {
  async fetch(request,env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ok:true,service:"ttactualidad-v2-private",configured:configured(env)});
    if (!configured(env)) return result("Acceso privado no configurado",503);
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
    if (url.pathname === "/api/marks") return redMarks(request,env);
    if (url.pathname.startsWith("/api/state/")) {
      if (request.method !== "GET") return json({error:"method_not_allowed"},405);
      const name = url.pathname.slice("/api/state/".length);
      if (!ALLOWED.has(name)) return json({error:"not_found"},404);
      const upstream=await fetch(SOURCE+name,{headers:{"Accept":"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
      if (!upstream.ok) return json({error:"source_unavailable"},502);
      const body=await upstream.text();
      if (body.length>2000000) return json({error:"oversized_source"},502);
      return result(body,200,{"Content-Type":"application/json; charset=utf-8"});
    }
    if (url.pathname === "/pilot/jordi-wild.webp") {
      if (request.method !== "GET") return json({error:"method_not_allowed"},405);
      const upstream=await fetch("https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/v2-tuit-radar-reevaluacion-piloto-20261114/v2/ttendencias/site/images/jordi-wild-r1-pilot-thumb.webp",{cf:{cacheTtl:3600,cacheEverything:true}});
      if (!upstream.ok) return json({error:"image_unavailable"},502);
      const data=await upstream.arrayBuffer();
      if(data.byteLength>500000) return json({error:"image_too_large"},502);
      return new Response(data,{headers:headers({"Content-Type":"image/webp"})});
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
