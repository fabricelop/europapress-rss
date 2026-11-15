// TTActualidad V2: radar de lectura independiente del PC y del cron no fiable de GitHub.
// Una ejecución cada 15 minutos en Cloudflare. No publica ni escribe el repositorio.
// El origen es GetDayTrends (tercero), nunca se presenta como X verificado.
export const RADAR_SOURCE = "https://getdaytrends.com/es/spain/";
const THIRTY = 30;

export function trendKey(value) {
  return String(value || "").trim().replace(/^#/, "").toLowerCase()
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/ß/g, "ss");
}
function fromHtml(value) {
  const entities = {amp:"&",lt:"<",gt:">",quot:'"',apos:"'",nbsp:" ",hellip:"…"};
  return String(value || "")
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (_all, key) => {
      const k=key.toLowerCase();
      if(k.startsWith("#")) {
        const point=k[1]==="x"?parseInt(k.slice(2),16):parseInt(k.slice(1),10);
        return Number.isInteger(point)&&point>0&&point<=0x10ffff?String.fromCodePoint(point):" ";
      }
      return entities[k] ?? " ";
    })
    .replace(/\s+/g, " ").trim();
}

export function parseGetDayTrends(html) {
  const ranking = new Map();
  let matchedTables = 0;
  for (const table of String(html).matchAll(/<table\b([^>]*)>([\s\S]*?)<\/table>/gi)) {
    const classMatch = /\bclass\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(table[1]);
    const classes = (classMatch?.[1] || classMatch?.[2] || "").split(/\s+/);
    if (!classes.includes("ranking") || !classes.includes("trends")) continue;
    matchedTables++;
    for (const row of table[2].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
      const cells = [...row[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)];
      if(cells.length<2)continue;
      const raw = fromHtml(cells[0][1]).replace(/^#/, "");
      if(!/^\d{1,2}$/.test(raw))continue;
      const rank=Number(raw),name=fromHtml(cells[1][1]);
      if(rank<1||rank>50||!name||name.length>100)continue;
      if(ranking.has(rank)&&trendKey(ranking.get(rank))!==trendKey(name))
        throw Error("RADAR_CONFLICTING_RANKS");
      ranking.set(rank,name);
    }
  }
  if(!matchedTables)throw Error("RADAR_SOURCE_MARKUP_UNKNOWN");
  const names=[];
  for(let rank=1;rank<=THIRTY;rank++){
    if(!ranking.has(rank))throw Error("RADAR_INCOMPLETE_TOP30");
    names.push(ranking.get(rank));
  }
  if(new Set(names.map(trendKey)).size!==THIRTY)throw Error("RADAR_DUPLICATED_TOP30");
  return names;
}

export function radarAgeMinutes(snapshot, clock=Date.now()) {
  const ms=Date.parse(snapshot?.captured_at || "");
  return Number.isFinite(ms)?Math.max(0,(clock-ms)/60000):Infinity;
}
export async function loadRadar(db) {
  if(!db)return null;
  const row=await db.prepare("SELECT payload FROM v2_radar WHERE id=1").first();
  if(!row?.payload)return null;
  const payload=JSON.parse(row.payload);
  return Array.isArray(payload.names)&&payload.names.length===THIRTY?payload:null;
}
export async function captureRadar(db, {fetcher=fetch, now=new Date()}={}) {
  if(!db)throw Error("RADAR_D1_MISSING");
  const response=await fetcher(RADAR_SOURCE,{
    headers:{"User-Agent":"Mozilla/5.0 (compatible; TTActualidadV2Radar/1.0)","Accept-Language":"es-ES,es;q=0.9","Cache-Control":"no-cache, no-store"},
    cf:{cacheTtl:0,cacheEverything:false}
  });
  if(!response.ok)throw Error("RADAR_SOURCE_HTTP_"+response.status);
  const html=await response.text();
  if(html.length<1500||html.length>2000000)throw Error("RADAR_SOURCE_SIZE_INVALID");
  const names=parseGetDayTrends(html);
  const timestamp=now.toISOString();
  const old=await loadRadar(db);
  if(old&&Date.parse(old.captured_at)>=now.getTime())return old;
  const prior=new Map((old?.names||[]).map((name,index)=>[trendKey(name),index+1]));
  const previousActive=new Map((old?.names||[]).map(name=>[trendKey(name),old.entered_at?.[trendKey(name)]||old.captured_at]));
  const entered={};
  const previous_ranks={};
  const movement_kinds={};
  const movement_at={};
  for(const [index,name] of names.entries()) {
    const k=trendKey(name);
    const rank=index+1;
    const prev=prior.get(k);
    entered[k]=previousActive.get(k)||timestamp;
    if(!old){
      previous_ranks[k]=null;
      movement_kinds[k]="baseline";
      movement_at[k]=null;
    }else if(prev===undefined){
      previous_ranks[k]=null;
      movement_kinds[k]="entry";
      movement_at[k]=timestamp;
    }else if(prev!==rank){
      previous_ranks[k]=prev;
      movement_kinds[k]=rank<prev?"up":"down";
      movement_at[k]=timestamp;
    }else{
      // A non-moving trend retains ITS last genuine delta even if other
      // trends changed. The previous cron tick is not a new movement.
      const oldRank=old.previous_ranks?.[k];
      const oldKind=old.movement_kinds?.[k];
      const kind=oldKind||(!Number.isInteger(oldRank)?"baseline":oldRank===rank?"baseline":oldRank>rank?"up":"down");
      movement_kinds[k]=kind;
      previous_ranks[k]=(kind==="up"||kind==="down")&&Number.isInteger(oldRank)&&oldRank!==rank?oldRank:null;
      movement_at[k]=old.movement_at?.[k]||null;
    }
  }
  const unchanged=old && names.every((name,index)=>trendKey(name)===trendKey(old.names[index]));
  const snapshot={
    version:1,
    source:RADAR_SOURCE,
    source_verified_against_x:false,
    captured_at:timestamp,
    previous_capture_at:old?.captured_at||null,
    unchanged_since:unchanged?(old.unchanged_since||old.captured_at):timestamp,
    identical_captures:unchanged?(old.identical_captures||1)+1:1,
    names,entered_at:entered,previous_ranks,movement_kinds,movement_at,
    last_change_at:unchanged?(old.last_change_at||null):timestamp,
    source_http_date:response.headers.get("date")||null,
    source_http_age:response.headers.get("age")||null,
    source_http_etag:response.headers.get("etag")||null
  };
  await db.prepare("INSERT INTO v2_radar(id,payload,updated_at) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at")
    .bind(JSON.stringify(snapshot),timestamp).run();
  console.log("TT_V2_CLOUDFLARE_RADAR_CAPTURE_OK",timestamp,"same",snapshot.identical_captures);
  return snapshot;
}

async function stableId(key) {
  const bytes=new TextEncoder().encode("ES|"+key);
  const hash=new Uint8Array(await crypto.subtle.digest("SHA-256",bytes));
  return "trv2-"+[...hash].map(x=>x.toString(16).padStart(2,"0")).join("").slice(0,24);
}

export async function mergeEditorialRadar(editorial, snapshot, clock=Date.now()) {
  if(!snapshot||!Array.isArray(snapshot.names)||snapshot.names.length!==THIRTY)
    return editorial;
  // Manual GitHub dispatch is a first-class backup. Whichever successful
  // capture is newer wins; an older Cloudflare snapshot cannot hide it.
  const githubTime=Date.parse(editorial?.captured_at||"");
  const cloudflareTime=Date.parse(snapshot.captured_at||"");
  if(Number.isFinite(githubTime)&&Number.isFinite(cloudflareTime)&&githubTime>cloudflareTime){
    return {...editorial,radar_source:"github_manual_or_latest",
      radar_last_captured_at:editorial.captured_at,
      radar_cloudflare_last_captured_at:snapshot.captured_at};
  }
  if(radarAgeMinutes(snapshot,clock)>45)
    return {...editorial,radar_source:"cloudflare_stale_fallback",radar_last_captured_at:snapshot.captured_at,
      radar_warning:"La captura de Cloudflare supera los 45 minutos; se muestra el último estado GitHub."};
  const byName=new Map((editorial.items||[]).map(item=>[trendKey(item.name),item]));
  const rows=[];
  for(let i=0;i<THIRTY;i++){
    const name=snapshot.names[i],key=trendKey(name),prev=snapshot.previous_ranks?.[key];
    const source=byName.get(key)||{};
    const rank=i+1;
    const previous_rank=Number.isInteger(prev)?prev:null;
    const diff=previous_rank===null?null:previous_rank-rank;
    const kind=snapshot.movement_kinds?.[key]||
      (diff===null?"entry":diff>0?"up":diff<0?"down":"baseline");
    rows.push({...source,rank,name,trend_id:source.trend_id||await stableId(key),
      entered_top30_at:snapshot.entered_at?.[key]||snapshot.captured_at,
      revision:source.revision||1,
      status:source.status||"pendiente",
      status_label:source.status_label||"Pendiente",
      editorial_status:source.editorial_status||"pending",
      explanation:source.explanation||"",
      movement:kind,
      previous_rank,positions_changed:diff
    });
  }
  const stuckMinutes=Math.max(0,(Date.parse(snapshot.captured_at)-Date.parse(snapshot.unchanged_since))/60000);
  return {...editorial,count:THIRTY,items:rows,captured_at:snapshot.captured_at,
    comparison_at:snapshot.previous_capture_at,radar_source:"cloudflare_cron_15m",
    ranking_unchanged:snapshot.identical_captures>1,
    ranking_change_at:snapshot.last_change_at||null,
    radar_identical_captures:snapshot.identical_captures,
    radar_unchanged_minutes:Math.floor(stuckMinutes),
    radar_source_verified_against_x:false,
    radar_warning:stuckMinutes>=45?"La fuente externa lleva "+Math.floor(stuckMinutes)+" minutos con el mismo Top 30. Su actualidad no está verificada.":null
  };
}
