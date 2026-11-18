"use strict";
// Ranking y marcas R comparten la misma instantánea validada por el Worker.
const BASE="/api/state/";
const $=id=>document.getElementById(id);
const state={items:[],captured:null,open:null,rankingUnchanged:false,rankingChangeAt:null,reRequests:[],incidentRequests:[],incidentRetryRequests:[],publications:{count:0,events:[]},manualImages:[]};
const newsViewMode=new URLSearchParams(location.search).get("view")==="noticias";
const PUBLIC_SITE='https://ttactualidad.rainyraven22.chatgpt.site';
function el(tag,className,content){const n=document.createElement(tag);if(className)n.className=className;if(content!==undefined)n.textContent=String(content);return n}
function valid(data){if(!data||data.project!=="ttactualidad-v2"||data.country!=="ES"||!Array.isArray(data.items)||data.items.length!==data.count||data.count<1||data.count>40)throw Error("Ranking no disponible");const ranks=new Set(data.items.map(x=>x.rank));if(ranks.size!==data.items.length||data.items.some(x=>!Number.isInteger(x.rank)||x.rank<1||x.rank>40||!x.name))throw Error("Ranking incoherente");return data}
function withoutInternalProvenance(text){
 return text
  .replace(/\b(?:figura|aparece|se encuentra) en (?:la relaci[oó]n|el listado|la lista|la clasificaci[oó]n) de tendencias (?:espa[nñ]olas|de Espa[nñ]a) (?:facilitad[ao]s? a|comunicad[ao]s? a|recibid[ao]s? por) TTActualidad\s*V2\.?/giu,"es tendencia en España.")
  .replace(/\b(?:figura|aparece|se encuentra) entre las tendencias (?:recibid[ao]s? por|facilitad[ao]s? a) TTActualidad\s*V2\.?/giu,"es tendencia en España.")
  .replace(/\b(?:seg[uú]n|para) TTActualidad\s*V2\b/giu,"según el listado de tendencias")
  .replace(/\bTTActualidad\s*V2\b/giu,"el listado de tendencias");
}
function capturedEditorial(raw){
 if(typeof raw!=="string")return "";
 return raw.replace(/\r\n?/g,"\n")
  .replace(/:::writing(?:\s*\{[^}\n]*\})?/giu,"")
  .replace(/(^|\s):::(?=\s|$)/gmu,"$1")
  // Remove ChatGPT editorial counters/hashtag diagnostics, not publishable prose.
  .replace(/(?:\s*[·|—–-]\s*)?\b\d{1,4}\s+caracteres\s*(?:[·|—–-]\s*)?sin\s+hashtags?\b\.?\s*$/gimu,"")
  .replace(/^\s*\d{1,4}\s+caracteres\s*$/gimu,"")
  .split("\n").map(line=>line.trim()
   .replace(/^#{1,6}\s+(?=\S)/u,"")
   .replace(/\*\*([^*\n]+)\*\*|__([^_\n]+)__/gu,"$1$2"))
  .filter(line=>!/^ESTADO_(?:CAUSA|X)\s*:/iu.test(line)
    &&! /^(?:Writing|Standard|Document)$/iu.test(line))
  .join("\n").replace(/\n{3,}/g,"\n\n").trim();
}
function isolateInlineEditorialSections(text){
 // Some captured chats flatten a whole dossier into one line. Restore a
 // boundary at an explicitly X-ready heading, even after a dossier title.
 return text.replace(/(?:Explicaci[oó]n principal|Hip[oó]tesis informativa principal)\s*(?:[—–:-]\s*)?(?:(?:texto\s+)?apt[ao]\s+para\s+X|para\s+X)(?:\s*\([^\n)]{0,100}\))?\s*:?\s*/giu,
  "\nExplicación principal — apta para X\n")
  // Long-form sections may also be flattened immediately after the X lead.
  .replace(/([^\n])\s+(?=(?:Qu[eé] ha ocurrido|Qu[eé] sabemos|Fuentes consultadas|Fuentes verificadas|Fuentes HTTPS|Lo que se sabe|Contexto y fuentes)\s+(?:[A-ZÁÉÍÓÚÑ#]|https?:\/\/))/gu,"$1\n\n");
}
function hasEditorialMetadata(text){
 // This is a final fail-closed guard, shared by the visible text and P-X.
 return /\bficha (?:de investigaci[oó]n|editorial|informativa)\b|\bhip[oó]tesis informativa (?:principal|predominante)\b|\bexplicaci[oó]n principal\s*(?:[—–:-]\s*)?(?:(?:texto\s+)?apt[ao]\s+para\s+X|para\s+X)\b|\bESTADO_(?:CAUSA|X)\s*:/iu.test(text);
}
function editorial(raw){
 if(typeof raw!=="string"||!raw.trim())return "Explicación pendiente.";
 const s=isolateInlineEditorialSections(capturedEditorial(raw)), lines=s.split("\n");
 // ChatGPT sometimes returns an editorial dossier headed by "Explicación
 // principal — apta para X". The main line is inside that section; the
 // dossier title, certainty labels and publication rules are NOT tweet text.
 const primary=/^\s*Explicaci[oó]n principal(?:\s*(?:[—–:-]\s*(?:apta|apto|texto\s+apto)\s+para\s+X|para\s+X))?(?:\s*\([^\n)]*\))?\s*:?\s*$/i;
 const secondary=/^\s*(?:Texto(?: editorial| propuesto)?(?: para LISTAS)?|Explicaci[oó]n para LISTAS|Explicaci[oó]n editorial|Explicaci[oó]n period[ií]stica(?:\s*(?:[—–:-]\s*)?LISTAS| para LISTAS)?|Texto para LISTAS)\s*:?\s*$/i;
 const primaryIndices=[],secondaryIndices=[];
 for(let i=0;i<lines.length;i++){
  if(primary.test(lines[i]))primaryIndices.push(i);
  else if(secondary.test(lines[i]))secondaryIndices.push(i);
 }
 // A recognised X-ready section is authoritative. Never use later dossier
 // sections as a fallback if that section happens to be empty or malformed.
 const candidates=[...primaryIndices.reverse(),...secondaryIndices.reverse()];
 if(!candidates.length)candidates.push(-1);
 for(const from of candidates){
  let out=[],started=false,hasProse=false;
  for(let i=from+1;i<Math.min(lines.length,from+24);i++){
   const line=lines[i].trim().replace(/^(?:(?:Writing|Standard|Document)\s+)+(?=\S)/iu,"");
   if(!line){
    // The X-ready lead is a standalone paragraph. Subsequent paragraphs and
    // their headings are context for LISTAS, never the P-X publication text.
    if(from>=0&&primary.test(lines[from])&&started)break;
    if(started&&out[out.length-1]!=="")out.push("");
    continue;
   }
   if(/^(?:Writing|Standard|Document|Texto editorial|Causa confirmada|Causa predominante acreditada)$/i.test(line))continue;
   if(/^(?:\s*¿?Por qu[eé] es tendencia\??|(?:¿?Qu[eé] ha ocurrido\??)|Qu[eé] sabemos|Lo que se sabe|Lo que no sabemos|Causa de la tendencia|Explicaci[oó]n principal|Explicaci[oó]n period[ií]stica|Contraste cronol[oó]gico|Fuentes verificadas|Fuentes consultadas|Fuentes HTTPS|Fuentes verificables|Fuentes y contraste|Control editorial|Conclusi[oó]n|Resultado(?: editorial| de la prueba)?|Presencia de la tendencia|L[ií]mite:|La causa est[aá]|La coincidencia temporal|Verificaci[oó]n|Referencias|Notas de cautela|Contexto y fuentes|Cronolog[ií]a|Justificaci[oó]n|Contexto adicional)/i.test(line))break;
   if(/^https?:\/\//i.test(line)||/^www\./i.test(line))break;
   if(/^(?:Tendencia:|Identificador:|Revisi[oó]n:|ESTADO_|ID:|Fecha:|Ficha editorial|Solo LISTAS|Sin publicaci[oó]n autom[aá]tica|Causa (?:identificada|probable|confirmada|no confirmada)|\d{1,2} de \p{L}+ de 20\d{2}\b)/iu.test(line))continue;
   if(/^[^\n]{1,100}\s+[—–]\s+Ficha editorial\s*$/iu.test(line))continue;
   if(!started&&line.length<40&&!line.startsWith("#")&&!/^(?:TT#|🌶)/u.test(line))continue;
   if(line.length>70)hasProse=true;
   started=true;
   out.push(line.replace(/^Hashtags:\s*/i,"").replace(/^(?:Remate|Chiste)(?:\s+[^:]{1,35})?:\s*/iu,""));
   if(line.includes("🌶"))break;
  }
  const value=out.join("\n").trim();
  if(hasProse&&value.length>60&&/[.!?]/u.test(value)&&!hasEditorialMetadata(value))
   return withoutInternalProvenance(value);
 }
 return "Explicación capturada; formato editorial pendiente de adaptar.";
}
const WEB_URL="https://fabricelop.github.io/europapress-rss/v2/";
function xLength(value){
 // URLs count as 23 characters in X; normal JS length is conservative for emoji.
 return value.replace(/https?:\/\/\S+/gu,"X".repeat(23)).length;
}
function completeProse(text,maxLength){
 const source=text.replace(/\s+/g," ").trim();
 if(xLength(source)<=maxLength)return source;
 // Never publish prose cut mid-sentence or with an ellipsis.
 const sentences=source.match(/[^.!?]+[.!?]+(?:[»”"']|$)?/gu)||[];
 let full="";
 for(const sentence of sentences){
  const candidate=(full+" "+sentence.trim()).trim();
  if(xLength(candidate)>maxLength)break;
  full=candidate;
 }
 if(full)return full;
 // Older, long editorial sentences: allow a complete independent first clause.
 let clause="";
 for(const match of source.matchAll(/[,;:]\s+|\s+[—–]\s+/gu)){
  const candidate=source.slice(0,match.index).trim();
  if(xLength(candidate+".")<=maxLength)clause=candidate;
 }
 if(clause&&!/\b(?:y|o|de|del|con|por|para|en|que|a|su|las|los|un|una)$/iu.test(clause))
  return clause.replace(/[,:;]$/u,"")+".";
 return "";
}
function trimTrendBoilerplate(text){
 // Only remove caveats about why a term is trending, never uncertainty about
 // the underlying facts. The stored editorial dossier stays unchanged.
 const trailing=/(?:\s+|^)(?:No se confirma que [^.]{0,70}(?:impuls[ae]|explique|provoque|motive) (?:la|esta) tendencia|No (?:se confirma|est[aá] confirmado) (?:el motivo|la causa) de (?:la|esta) tendencia|La causa concreta de (?:la|esta) tendencia no est[aá] confirmada)\.?\s*$/iu;
 const shortened=String(text||"").replace(trailing,"").trim();
 return shortened.length>=25?shortened:text;
}
function tweetText(raw,item){
 const extracted=editorial(raw);
 const adapted=publishableText(extracted)?null:dossierSummary(raw,item);
 // Never fall back to an unsafe raw capture when the dossier adapter fails.
 const source=publishableText(extracted)?extracted:
  publishableText(adapted?.prose)?adapted.prose:extracted.startsWith("Explicación pendiente")?extracted:
  "Explicación capturada; formato editorial pendiente de adaptar.";
 if(source.startsWith("Explicación pendiente")||source.startsWith("Explicación capturada"))return source;
 const rank=Number.isInteger(item?.rank)?item.rank:0;
 const name=String(item?.name||"TENDENCIA").toLocaleUpperCase("es-ES").trim();
 const lines=source.split("\n").map(x=>x.trim()).filter(Boolean);
 const jokeLine=lines.find(x=>x.includes("🌶"))||"";
 // Editorial notes are metadata: never send labels such as "Remate suave" to X.
 const joke=jokeLine.replace(/^(?:Remate|Chiste)(?:\s+[^:]{1,35})?:\s*/iu,"").trim();
 const hashLine=lines.filter(x=>!x.includes("🌶")&&(/^(?:Hashtags:\s*)?#\S+/i.test(x)||/^Hashtags:\s*#/i.test(x))).map(x=>x.replace(/^Hashtags:\s*/i,"").trim()).join(" ");
 const hashes=[...new Set((hashLine.match(/#[\p{L}\p{N}_]+/gu)||[]))].join(" ");
 let prose=lines.filter(x=>!x.includes("🌶")&&!/^Hashtags:\s*/i.test(x)&&!/^\s*#[\p{L}\p{N}_]+(?:\s+#[\p{L}\p{N}_]+)*\s*$/u.test(x)).join(" ").replace(/\s+/g," ").trim();
 prose=trimTrendBoilerplate(prose);
 // Metadata wins over wording: never present a probable cause as established.
 const startsWithName=prose.toLocaleUpperCase("es-ES").startsWith(name+" ");
 const initial=startsWithName?prose.slice(name.length).trim():prose;
 const uncertain=adapted?.uncertain===true||/^\s*ESTADO_CAUSA\s*:\s*NO_CONFIRMADA\s*$/im.test(String(raw||""))
  ||item?.cause_status==="no_confirmada"
  ||/^podr[íi]a ser tendencia\b/iu.test(initial);
 const prefix="TT#"+rank+" "+name+(uncertain?"":" es tendencia");
 // Remove an already written lead only if it is the same trend and prefix.
 prose=prose.replace(/^TT#\d+\s+/iu,"");
 const lead=name+" ES TENDENCIA";
 if(prose.toLocaleUpperCase("es-ES").startsWith(lead)){
  const rest=prose.slice(lead.length).replace(/^\s*[:,]?\s*/u,"");
  prose=uncertain?"podría ser tendencia"+(rest?" "+rest:""):rest;
 }
 // Preserve grammatical meaning when the raw text begins with its own trend name.
 else if(prose.toLocaleUpperCase("es-ES").startsWith(name+" ")){
  const rest=prose.slice(name.length).trim();
  if(uncertain){
   prose=/^es tendencia\b/iu.test(rest)?rest.replace(/^es tendencia\b/iu,"podría ser tendencia")
    :/^(?:por|porque|tras|ante|debido|en |al |a raíz)/iu.test(rest)?"podría ser tendencia "+rest:rest;
  }else prose=/^(?:por|porque|tras|ante|debido|en |al |a raíz)/iu.test(rest)?rest:"porque "+rest;
 }
 if(!prose)return prefix+".";
 // The conditional/neutral heading conveys uncertainty. Do not append a
 // repetitive disclaimer that swallows useful X copy or ends each explanation.
 const explanation=completeProse(prose,280-xLength(prefix)-2);
 if(!explanation)return prefix+". Consulta la explicación íntegra en la ficha.";
 // Explicit priority: A explanation, B full punchline, C whole tags, D URL.
 const joinsDirectly=uncertain?/^podr[íi]a ser tendencia\b/iu.test(explanation)
  :/^(?:porque |por |tras |ante |debido |en |al |a raíz)/iu.test(explanation);
 const parts=[prefix+(joinsDirectly?" ":": ")+explanation];
 for(const component of [joke,hashes,WEB_URL]){
  if(component&&xLength(parts.join("\n")+"\n"+component)<=280)parts.push(component);
 }
 return parts.join("\n");
}
function publishableText(text){
 return !!text&&!/^Explicación (?:pendiente|capturada)/u.test(text)&&!hasEditorialMetadata(text);
}
function dossierSummary(raw,item){
 const lines=capturedEditorial(raw).split("\n");
 // Prefer the dossier's own explicit hypothesis to unrelated schedule facts.
 // This works for any topic; no trend names or topic-specific prose are used.
 const hypothesis=lines.map(line=>line.match(/^Hip[oó]tesis (?:principal|predominante)\s*:\s*(.+)$/iu))
  .find(Boolean)?.[1];
 if(hypothesis&&hypothesis.length>12&&!/https?:|ESTADO_|Ficha editorial/iu.test(hypothesis)&&!hasEditorialMetadata(hypothesis)){
  const text=hypothesis.replace(/[.!?]+$/u,"");
  return {prose:"Posible relación: "+text+".",uncertain:true};
 }
 const confirmed=/^\s*ESTADO_CAUSA\s*:\s*CONFIRMADA\s*$/imu.test(String(raw||""))
  &&item?.cause_status!=="no_confirmada";
 for(let i=0;i<lines.length;i++){
  if(!/^(?:Qu[eé] sabemos|Qu[eé] ha ocurrido|Resumen(?: breve| editorial)?|Explicaci[oó]n period[ií]stica)\s*:?$/iu.test(lines[i]))continue;
  const paragraph=[];
  for(let j=i+1;j<lines.length;j++){
   const line=lines[j].trim();
   if(!line){if(paragraph.length)break;continue;}
   if(/^(?:https?:|Fuentes|Comprobaci[oó]n|Enlaces|Verificaci[oó]n|Destino editorial|Valoraci[oó]n)/iu.test(line))break;
   if(/^\+?\d+$|^\d{1,2} de \p{L}+ de 20\d{2}$/iu.test(line))continue;
   paragraph.push(line);
  }
  const prose=paragraph.join(" ");
  if(prose.length>60&&/[.!?]/u.test(prose)&&!hasEditorialMetadata(prose))return {prose,uncertain:!confirmed};
 }
 return null;
}
function explanationText(raw,item){
 // V2 is the X composer: the displayed copy is exactly what both X actions use.
 // The full original dossier remains in the source for the long-form V1 flow.
 return tweetText(raw,item);
}
// Server-side marks: same state on every authenticated browser and device.
let redMarks={};
let refreshing=false;
function markStamp(item){return typeof item.entered_top30_at==="string"?item.entered_top30_at:""}
function isMarked(item){return Object.prototype.hasOwnProperty.call(redMarks,item.trend_id)}
async function loadSharedMarks() {
 const res=await fetch("/api/marks",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("No se pueden sincronizar las marcas R (HTTP "+res.status+")");
 const data=await res.json();
 if(!data.marks||typeof data.marks!=="object")throw Error("Respuesta de marcas no válida");
 redMarks=data.marks;
}
async function loadReRequests(){
 const res=await fetch("/api/re-explain",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("No se puede consultar RE (HTTP "+res.status+")");
 const data=await res.json();
 if(!Array.isArray(data.requests))throw Error("Respuesta RE no válida");
 state.reRequests=data.requests;
}
async function loadIncidentRequests(){
 const res=await fetch("/api/incident-rex",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("No se pueden consultar las pistas pendientes (HTTP "+res.status+")");
 const data=await res.json();
 if(!Array.isArray(data.requests))throw Error("Solicitudes de incidencias no válidas");
 state.incidentRequests=data.requests;
}
async function loadIncidentRetryRequests(){
 const res=await fetch("/api/incident-retry",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("No se pueden consultar los reintentos manuales (HTTP "+res.status+")");
 const data=await res.json();
 if(!Array.isArray(data.requests))throw Error("Respuesta de reintentos no válida");
 state.incidentRetryRequests=data.requests;
}
function incidentRequested(item){
 return state.incidentRequests.some(row=>row.trend_id===item.trend_id&&row.base_revision===item.revision);
}
function incidentRetryRequested(item){
 return state.incidentRetryRequests.some(row=>row.trend_id===item.trend_id&&row.base_revision===item.revision);
}
function renderPublications(){
 const data=state.publications;
 const summary=$("publication-summary");
 summary.textContent=(newsViewMode?"PUB":"PU")+" · "+data.count+" / 24 h";
 summary.title="Ver "+data.count+" publicaciones de "+(newsViewMode?"Noticias":"Tendencias")+" registradas en las últimas 24 horas móviles";
 $("publication-heading").textContent="Publicaciones de "+(newsViewMode?"Noticias":"Tendencias")+" · últimas 24 horas";
 const list=$("publication-history");list.replaceChildren();
 for(const event of data.events){
  const date=new Date(event.pressed_at_ms);
  if(!Number.isFinite(date.getTime()))continue;
  const when=new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",dateStyle:"short",timeStyle:"medium"}).format(date);
  const entry=el("li","",when+" · "+String(newsViewMode?(event.news_title||"Noticia"):(event.trend_name||"Tendencia")));
  list.append(entry);
 }
 if(!list.children.length)list.append(el("li","","Ninguna publicación registrada en las últimas 24 horas."));
}
async function loadPublications(){
 const res=await fetch(newsViewMode?"/api/news-publication-count":"/api/publication-count",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("Contador de publicaciones no disponible (HTTP "+res.status+")");
 const data=await res.json();
 if(!Number.isSafeInteger(data.count)||!Array.isArray(data.events))throw Error("Contador de publicaciones incoherente");
 state.publications=data;
 renderPublications();
}
async function loadManualImages(){
 const res=await fetch(PUBLIC_SITE+'/api/manual-v2-image/catalog',{cache:'no-store',credentials:'omit'});
 if(!res.ok)throw Error('Catálogo manual HTTP '+res.status);
 const data=await res.json();
 if(data.schema_version!==1||!Array.isArray(data.images))throw Error('Catálogo manual inválido');
 state.manualImages=data.images.filter(x=>/^trv2-[a-f0-9]{24}$/.test(x.trend_id)&&
   Number.isSafeInteger(x.revision)&&/^[a-f0-9]{64}$/.test(x.sha256)&&
   x.image_url===PUBLIC_SITE+'/images/v2-manual/'+x.trend_id+'-r'+x.revision+'-'+x.sha256.slice(0,12)+'.'+({'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[x.mime]||''));
}
function applyManualImages(){
 for(const item of state.items){
  const saved=state.manualImages.find(x=>x.trend_id===item.trend_id&&x.revision===item.revision);
  item.manual_image_url=saved?.image_url||null;
 }
}
function reRequested(item){
 return state.reRequests.some(row=>row.trend_id===item.trend_id&&row.base_revision===item.revision);
}
function reResetPending(item){return item.re_in_progress===true||reRequested(item)}
async function toggleRedMark(item,card,button){
 if(button.disabled)return;
 button.disabled=true;
 const next=!isMarked(item);
 try{
  const res=await fetch("/api/marks",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({trend_id:item.trend_id,entered_top30_at:markStamp(item),marked:next})});
  if(!res.ok)throw Error("HTTP "+res.status);
  if(next)redMarks[item.trend_id]=markStamp(item);else delete redMarks[item.trend_id];
  // Another tab/device can change the same R; reload server truth on refresh.
  card.classList.toggle("marked-red",next);
  button.setAttribute("aria-pressed",String(next));
  button.setAttribute("aria-label",next?"Quitar marca roja de "+item.name:"Marcar en rojo "+item.name);
  button.title=next?"Quitar marca roja":"Marcar en rojo";
 }catch(error){
  $("notice").textContent=error.message==="HTTP 409"?
   "El Top 30 ha cambiado desde que abriste esta lista. Actualiza para marcar las tendencias vigentes.":
   "No se ha guardado la marca R. Comprueba la conexión e inténtalo de nuevo.";
  $("notice").hidden=false;
 }finally{button.disabled=false}
}
function spanishStamp(value){
 const date=new Date(value);
 return Number.isFinite(date.getTime())?new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"}).format(date):null;
}
function explanationTime(item){
 if(item.status!=="explicada"||!item.captured_at)return null;
 const stamp=spanishStamp(item.captured_at);
 if(!stamp)return null;
 const e=el("time","explained-at",stamp);
 e.dateTime=item.captured_at;
 e.title="Explicación guardada: "+stamp+" (hora peninsular)";
 e.setAttribute("aria-label",e.title);
 return e;
}
function movementIndicator(item){
 const meta=item._rankingMeta||{};
 const previous=Number.isInteger(item.previous_rank) && item.previous_rank>=1 && item.previous_rank<=40?item.previous_rank:null;
 let label="—",description="Sin captura anterior comparable",kind="unknown";
 if(previous!==null){
  const difference=previous-item.rank;
  if(difference>0){label="↑ "+difference;description="Sube "+difference+" puesto"+(difference===1?"":"s")+" desde el "+previous;kind="up"}
  else if(difference<0){label="↓ "+(-difference);description="Baja "+(-difference)+" puesto"+(difference===-1?"":"s")+" desde el "+previous;kind="down"}
  else{label="—";description="Sin nuevo cambio de posición acreditado";kind="same"}
 }else if(["reentry","short_return"].includes(item.movement)){
  label="Vuelve";description="Regresa al Top 30 después de haber salido";kind="return";
 }else if(item.movement==="entry"){
  label="Nueva";description="Entra por primera vez en el Top 30";kind="entry";
 }
 if(meta.rankingUnchanged){
  const stamp=meta.rankingChangeAt?spanishStamp(meta.rankingChangeAt):null;
  description+=". Última consulta con Top 30 idéntico; se conserva la comparación anterior"+(stamp?" ("+stamp+")":"");
 }
 const badge=el("span","movement-indicator "+kind+(meta.rankingUnchanged?" held":""),label);
 badge.title=description;
 badge.setAttribute("aria-label",description);
 return badge;
}
function top30Since(item){
 const stamp=spanishStamp(item.entered_top30_at);
 if(!stamp)return null;
 const returning=["reentry","short_return"].includes(item.movement);
 const node=el("time","entered-top30",(returning?"Regresó el ":"Desde ")+stamp);
 node.dateTime=item.entered_top30_at;
 node.title=(returning?"Último regreso al Top 30: ":"Entrada en el Top 30: ")+stamp+" (hora peninsular)";
 return node;
}
function attachGeneratedImage(card,item){
  // Only request the original if this editorial revision has a verified image.
  if(!imageReady(item))return;
  const wrap=el("div","trend-generated-image");
  const status=el("p","image-load-status","Cargando imagen IA…");
  status.setAttribute("role","status");
  const picture=el("img","generated-original");
  picture.alt="Ilustración editorial de "+item.name;
  // An image with loading=lazy inside a display:none parent might never
  // be requested, and the load event can never make that parent visible.
  picture.loading="eager";
  picture.decoding="async";
  picture.hidden=true;
  picture.addEventListener("load",()=>{picture.hidden=false;wrap.classList.add("loaded");status.hidden=true});
  picture.addEventListener("error",()=>{
   picture.hidden=true;wrap.classList.remove("loaded");
   status.hidden=false;status.textContent="No se pudo cargar la imagen IA. Cierra y vuelve a abrir la ficha para reintentar.";
   requested=false;
  });
  wrap.append(status,picture);card.append(wrap);
  let requested=false;
  const openImage=()=>{
   if(requested||!card.open)return;
   requested=true;
   picture.src=item.manual_image_url||"/api/image/"+encodeURIComponent(item.trend_id)+"?revision="+item.revision;
  };
  card.addEventListener("toggle",openImage);
  openImage();
}
function imageReady(item){
 return (item.image_available===true||!!item.manual_image_url)&&item.image_suppressed!==true&&
   !reResetPending(item)&&item.status==="explicada"&&
   /^trv2-[a-f0-9]{24}$/.test(item.trend_id)&&
   Number.isSafeInteger(item.revision)&&item.revision>=1;
}
function imageRetryHint(item){
 if(item.status!=="explicada"||imageReady(item)||item.image_suppressed===true)return null;
 const retry=item.image_retry||{};
 let message;
 switch(retry.state){
  case "generating":message="Imagen IA: generándose automáticamente.";break;
  case "retry_pending":
   message="Imagen IA: reintento automático pendiente · "+retry.remaining+" envíos disponibles de 3";
   if(Number.isInteger(retry.pre_send_failures)&&retry.pre_send_failures>0)
    message+=" · fallos previos al envío "+retry.pre_send_failures+"/3";
   message+=".";break;
  case "exhausted":message="Imagen IA: intentos automáticos agotados. Puedes generar y pegar la imagen manualmente.";break;
  case "blocked":message="Imagen IA: intento no verificable; no habrá más intentos automáticos hasta revisión manual.";break;
  case "pending":message="Imagen IA: pendiente de generación automática.";break;
  default:message="Imagen IA: todavía no hay un registro verificable de intentos. No se puede confirmar si quedan reintentos.";
 }
 const label=el("p","image-retry-status",message);
 label.setAttribute("role","status");
 return label;
}
function openManualPasteDialog(item){
 const dialog=el('dialog','manual-image-dialog');
 const title=el('h3','','Pegar imagen · '+item.name+' (revisión '+item.revision+')');
 const description=el('p','','Copia el original desde Mis imágenes de ChatGPT. Toca la zona de abajo y usa Pegar. También puedes elegir la imagen desde Fotos o Archivos. Tras confirmar, se asociará a esta tendencia en V2 y en la web pública V1.');
 const target=el('div','image-paste-zone','Mantén pulsado aquí y elige «Pegar imagen»');
 target.contentEditable='true';target.setAttribute('role','textbox');target.setAttribute('aria-label','Pegar imagen desde el portapapeles');
 const fileInput=el('input','image-file-picker');fileInput.type='file';fileInput.accept='image/png,image/jpeg,image/webp';
 const preview=el('img','manual-image-preview');preview.alt='Previsualización del original pegado';preview.hidden=true;
 const message=el('p','manual-image-message','');message.setAttribute('role','status');
 const actions=el('div','re-x-actions');
 const cancel=el('button','','Cancelar');cancel.type='button';
 const save=el('button','re-x-submit','Asociar en V2 y V1');save.type='button';save.disabled=true;
 let chosen=null,localURL=null;
 function choose(file){
  if(!file||!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size<10000||file.size>8*1024*1024){
   message.textContent='Necesito el archivo real PNG, JPG o WebP (máximo 8 MB). Si el portapapeles solo trae un enlace, usa Fotos/Archivos.';return;
  }
  chosen=file;save.disabled=false;
  if(localURL)URL.revokeObjectURL(localURL);
  localURL=URL.createObjectURL(file);preview.src=localURL;preview.hidden=false;
  target.textContent='Imagen recibida · '+Math.round(file.size/1024)+' KB';message.textContent='Comprueba la imagen antes de asociarla.';
 }
 target.addEventListener('paste',event=>{
  const files=[...(event.clipboardData?.files||[])];
  for(const entry of event.clipboardData?.items||[]){const file=entry.type.startsWith('image/')?entry.getAsFile():null;if(file)files.push(file)}
  if(files.length){event.preventDefault();choose(files[0])}
 });
 target.addEventListener('input',async()=>{
  const pasted=target.querySelector('img');
  if(!pasted)return;
  const source=pasted.getAttribute('src')||'';
  target.textContent='Comprobando imagen pegada…';
  if(!/^(?:data:image\/(?:png|jpeg|webp);base64,|blob:)/i.test(source)){
   message.textContent='Se ha pegado un enlace, no los bytes de la imagen. Utiliza «Elegir imagen».';return;
  }
  try{const response=await fetch(source);choose(await response.blob())}catch{message.textContent='No se pudieron leer los bytes de la imagen pegada.'}
 });
 fileInput.addEventListener('change',()=>choose(fileInput.files?.[0]));
 cancel.addEventListener('click',()=>dialog.close());
 save.addEventListener('click',async()=>{
  if(!chosen)return;
  if(!window.confirm('¿Asociar la imagen de «'+item.name+'» a su revisión '+item.revision+' y mostrarla también en la web pública V1?'))return;
  save.disabled=true;cancel.disabled=true;message.textContent='Verificando y asociando el original…';
  try{
   const buffer=await chosen.arrayBuffer();
   const sha=[...new Uint8Array(await crypto.subtle.digest('SHA-256',buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
   const claim=await fetch('/api/manual-image-ticket',{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json','x-ttv2-action':'1'},body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,sha256:sha,mime:chosen.type,bytes:buffer.byteLength})});
   if(!claim.ok)throw Error('La tendencia ha cambiado o no admite imagen (HTTP '+claim.status+'). Actualiza.');
   const ticket=(await claim.json()).ticket;
   const form=new FormData();form.set('ticket',ticket);form.set('trend_id',item.trend_id);form.set('revision',String(item.revision));form.set('image',new File([buffer],'imagen.'+({'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[chosen.type]),{type:chosen.type}));
   const upload=await fetch(PUBLIC_SITE+'/api/manual-v2-image',{method:'POST',body:form,credentials:'omit'});
   const done=await upload.json();
   if(!upload.ok||done.image?.sha256!==sha||done.image?.trend_id!==item.trend_id||done.image?.revision!==item.revision)throw Error(done.error||'No se pudo verificar la asociación en V1');
   item.manual_image_url=done.image.image_url;
   state.manualImages=state.manualImages.filter(x=>x.trend_id!==item.trend_id||x.revision!==item.revision);
   state.manualImages.push(done.image);
   // An explicit manual attachment is also the owner's public visibility choice.
   const visibility=await fetch('/api/image-visibility',{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json','x-ttv2-action':'1'},body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,scope:'public',visible:true})});
   if(!visibility.ok)throw Error('Imagen guardada en V1, pero no se pudo confirmar su visibilidad pública. Usa «Imagen en V1».');
   item.public_image_visible=true;
   publishNotice('Imagen real asociada a «'+item.name+'» (r'+item.revision+') en V2 y V1. Ninguna publicación automática.');
   dialog.close();render();
  }catch(error){message.textContent='No se completó: '+error.message;save.disabled=false;cancel.disabled=false}
 });
 actions.append(cancel,save);dialog.append(title,description,target,fileInput,preview,message,actions);
 dialog.addEventListener('close',()=>{if(localURL)URL.revokeObjectURL(localURL);dialog.remove()},{once:true});
 document.body.append(dialog);dialog.showModal();target.focus();
}
function publishNotice(message){
 const notice=$("notice");notice.textContent=message;notice.hidden=false;
}
function manualImagePrompt(item){
 if(!/^trv2-[a-f0-9]{24}$/.test(item.trend_id)||!Number.isSafeInteger(item.revision)||item.revision<1)
  throw Error("Identidad editorial no válida. Actualiza la tendencia.");
 const brief=String(item.explanation||"").replace(/\s+/g," ").trim().slice(0,6000);
 if(brief.length<60)throw Error("Todavía no hay una explicación completa para generar el gag.");
 const styles=["cómic europeo editorial con personajes expresivos y dibujo nítido",
  "grabado moderno con volumen, luces y humor narrativo",
  "tinta y acuarela con profundidad, textura y una escena viva",
  "caricatura editorial 3D con iluminación cinematográfica"];
 let seed=0;
 for(const ch of item.trend_id)seed=(seed*31+ch.charCodeAt(0))>>>0;
 const style=styles[seed%styles.length];
 return "TT_V2_IMAGE_MANUAL_V1 "+item.trend_id+"-r"+item.revision+" | "+
  "Usa ImageGen AHORA y genera UNA SOLA imagen GAG original. "+
  "Este es un CHAT NUEVO e independiente: no busques la conversación editorial, no investigues ni reescribas la explicación. "+
  "Tendencia: "+item.name+". Identificador: "+item.trend_id+". Revisión: "+item.revision+". "+
  "TEXTO EDITORIAL YA EXPLICADO (fuente del gag; no lo reescribas): "+brief+". "+
  "DIRECCIÓN VISUAL: "+style+". Aplica el estilo editorial V1: una escena narrativa única, protagonistas, "+
  "acción reconocible, metáfora o exageración visual relacionada con el hecho, profundidad, expresiones y textura. "+
  "Una sola idea que se entienda en 1-2 segundos sin leer texto, acabado profesional, mínimo 1024px de ancho. "+
  "No esquemas, infografías, flechas, conectores, paneles, avatares flotantes, collage ni medallones. "+
  "Cero titulares, hashtags, rótulos, marcas de agua, texto superpuesto, guindillas o símbolos 🌶️. "+
  "En sucesos graves no hagas humor a costa de las víctimas. Si la causa no está confirmada, "+
  "no representes hipótesis como hechos. No publiques en redes ni modifiques GitHub. "+
  "El usuario copiará manualmente la imagen final en «Pegar IA» de la misma tendencia V2.";
}
function showManualImagePrompt(prompt,item){
 const dialog=el("dialog","re-x-dialog");
 const heading=el("h3","","Prompt IA · "+item.name);
 const intro=el("p","","Selecciona y copia este texto. Pégalo en un chat nuevo de ChatGPT y después usa «Pegar IA» en esta ficha.");
 const textarea=el("textarea","re-x-hints");textarea.readOnly=true;textarea.value=prompt;
 textarea.setAttribute("aria-label","Prompt completo para generar imagen IA");
 const actions=el("div","re-x-actions");
 const close=el("button","","Cerrar");close.type="button";
 close.addEventListener("click",()=>dialog.close());
 actions.append(close);dialog.append(heading,intro,textarea,actions);
 dialog.addEventListener("close",()=>dialog.remove(),{once:true});
 document.body.append(dialog);dialog.showModal();textarea.focus();textarea.select();
}
async function copyManualImagePrompt(item){
 const prompt=manualImagePrompt(item);
 try{
  if(!navigator.clipboard?.writeText)throw Error("Sin acceso al portapapeles");
  await navigator.clipboard.writeText(prompt);
  publishNotice("Prompt IA copiado para «"+item.name+"» (r"+item.revision+"). Pégalo en un chat nuevo de ChatGPT y vuelve a «Pegar IA».");
 }catch{
  showManualImagePrompt(prompt,item);
 }
}
function openReXDialog(item,onSubmit){
 const dialog=el("dialog","re-x-dialog");
 const heading=el("h3","","RE-X · "+item.name);
 const intro=el("p","","Escribe qué conversación, publicación, palabra clave o dato quieres que investigue en X. Las pistas se contrastarán; no se darán por ciertas.");
 const textarea=el("textarea","re-x-hints");
 textarea.rows=6;textarea.maxLength=1200;textarea.placeholder="Por ejemplo: se está comentando un vídeo publicado hoy por…; busca también #…";
 textarea.setAttribute("aria-label","Pistas para la investigación en X");
 const privacy=el("small","re-x-privacy","No incluyas datos personales ni confidenciales: las pistas quedarán visibles en el repositorio público del proyecto.");
 const error=el("p","re-x-error","");error.setAttribute("role","alert");
 const buttons=el("div","re-x-actions");
 const cancel=el("button","","Cancelar");cancel.type="button";
 const submit=el("button","re-x-submit","Pedir RE-X");submit.type="button";
 cancel.addEventListener("click",()=>dialog.close());
 submit.addEventListener("click",async()=>{
   const hints=textarea.value.trim();
   if(hints.length<10){error.textContent="Escribe al menos 10 caracteres.";textarea.focus();return}
   submit.disabled=true;cancel.disabled=true;error.textContent="";
   try{await onSubmit(hints);dialog.close()}
   catch(e){error.textContent="No se pudo pedir RE-X: "+e.message;submit.disabled=false;cancel.disabled=false}
 });
 buttons.append(cancel,submit);dialog.append(heading,intro,textarea,privacy,error,buttons);
 dialog.addEventListener("close",()=>dialog.remove(),{once:true});
 document.body.append(dialog);dialog.showModal();textarea.focus();
}
function appendEditorialReButtons(editing,item){
 const re=el("button","publish-action re-explain-action","RE");
 re.type="button";
 re.title=item.status==="en_elaboracion"?"Programar una nueva investigación tras el chat actual":"Reiniciar investigación editorial";
 re.setAttribute("aria-label","Volver a investigar y explicar "+item.name);
 re.disabled=item.re_in_progress===true||reRequested(item);
 re.addEventListener("click",async()=>{
  if(re.disabled)return;
  const confirmText=item.status==="en_elaboracion"?
    "«"+item.name+"» ya tiene un chat trabajando. ¿Pedir otra revisión cuando termine, sin interrumpirlo?":
    item.status==="pendiente"?
    "¿Priorizar una investigación nueva de «"+item.name+"»? Aún no tiene explicación guardada.":
    "¿Reiniciar por completo la explicación de «"+item.name+"»? Se retirarán temporalmente el texto y la imagen actuales.";
  if(!window.confirm(confirmText))return;
  re.disabled=true;
  try{
   const response=await fetch("/api/re-explain",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,entered_top30_at:markStamp(item)})});
   if(!response.ok)throw Error("HTTP "+response.status);
   state.reRequests.push({trend_id:item.trend_id,base_revision:item.revision,status:"requested"});
   re.title="Nueva explicación solicitada; esperando procesamiento";
   publishNotice("RE solicitada para «"+item.name+"». "+(item.status==="en_elaboracion"?"Se programará después del chat actual, sin interrumpirlo.":item.status==="pendiente"?"Se priorizará una investigación nueva.":"Se prepararán una explicación y una imagen nuevas."));
   render();
  }catch(error){
   re.disabled=false;
   publishNotice("No se pudo solicitar RE para «"+item.name+"»: "+error.message);
  }
 });
 const reX=el("button","publish-action re-x-action","RE-X");
 reX.type="button";reX.title="Reevaluar buscando en X con tus pistas";
 reX.setAttribute("aria-label","Investigar de nuevo "+item.name+" en X con pistas");
 reX.disabled=item.re_in_progress===true||reRequested(item);
 reX.addEventListener("click",()=>{
   if(reX.disabled)return;
   openReXDialog(item,async hints=>{
     const response=await fetch("/api/re-explain",{method:"POST",credentials:"same-origin",
       headers:{"content-type":"application/json","x-ttv2-action":"1"},
       body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,
         entered_top30_at:markStamp(item),mode:"x",hints})});
     if(!response.ok)throw Error("HTTP "+response.status);
     state.reRequests.push({trend_id:item.trend_id,base_revision:item.revision,
       status:"requested",mode:"x"});
     publishNotice("RE-X solicitada para «"+item.name+"». Tus pistas se incorporarán al "+(item.status==="en_elaboracion"?"próximo chat, cuando finalice el actual.":"nuevo chat de investigación."));
     render();
   });
 });
 editing.append(re,reX);
}
function makePublishButtons(card,item){
 if(item.status==="incidencia"){
  const actions=el("div","publish-actions trend-actions");
  const review=el("div","news-action-group news-action-editing");
  review.setAttribute("role","group");review.setAttribute("aria-label","Gestión y reelaboración");
  review.append(el("span","news-action-caption","Gestión y reelaboración"));
  const button=el("button","publish-action re-x-action","RE-X");
  button.type="button";
  button.title="Aportar pistas a X para recuperar la elaboración interrumpida";
  button.setAttribute("aria-label","Aportar pistas RE-X a la incidencia de "+item.name);
  button.disabled=incidentRequested(item);
  button.addEventListener("click",()=>{
   if(button.disabled)return;
   openReXDialog(item,async hints=>{
    const response=await fetch("/api/incident-rex",{method:"POST",credentials:"same-origin",
     headers:{"content-type":"application/json","x-ttv2-action":"1"},
     body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,hints})});
    if(!response.ok)throw Error("HTTP "+response.status);
    state.incidentRequests.push({trend_id:item.trend_id,base_revision:item.revision});
    state.incidentRetryRequests.push({trend_id:item.trend_id,base_revision:item.revision});
     publishNotice("RE-X solicitada para «"+item.name+"». Tus pistas se aplicarán al nuevo intento tras verificar el cierre seguro del anterior.");
    render();
   });
  });
  review.append(button);
  if(button.disabled)review.append(el("span","review-state","Pistas RE-X recibidas · esperando otro intento"));
  const retry=el("button","publish-action re-explain-action","RE");
  retry.type="button";
  retry.title="Solicitar un nuevo intento desde cero y con un chat distinto";
  retry.setAttribute("aria-label","Reintentar la elaboración de "+item.name+" desde cero");
  retry.disabled=incidentRetryRequested(item);
  retry.addEventListener("click",async()=>{
   if(retry.disabled)return;
   retry.disabled=true;
   try{
    const response=await fetch("/api/incident-retry",{method:"POST",credentials:"same-origin",
     headers:{"content-type":"application/json","x-ttv2-action":"1"},
     body:JSON.stringify({trend_id:item.trend_id,revision:item.revision})});
    if(!response.ok)throw Error("HTTP "+response.status);
    state.incidentRetryRequests.push({trend_id:item.trend_id,base_revision:item.revision});
    publishNotice("Reintento solicitado para «"+item.name+"». Se abrirá otro chat después de comprobar el cierre seguro del intento anterior.");
    render();
   }catch(e){retry.disabled=false;publishNotice("No se pudo solicitar el reintento: "+e.message);}
  });
  review.append(retry);
  if(retry.disabled)review.append(el("span","review-state","Reintento solicitado"));
  actions.append(review);
  card.append(actions);
  return;
 }
 if(item.status==="pendiente"||item.status==="en_elaboracion"){
  const actions=el("div","publish-actions trend-actions");
  const editing=el("div","news-action-group news-action-editing");
  editing.setAttribute("role","group");
  editing.setAttribute("aria-label","Gestión y reelaboración");
  editing.append(el("span","news-action-caption","Gestión y reelaboración"));
  appendEditorialReButtons(editing,item);
  actions.append(editing);
  card.append(actions);
  return;
 }
 if(item.status!=="explicada")return;
 const text=tweetText(item.explanation,item);
 if(text.startsWith("Explicación pendiente"))return;
 const actions=el("div","publish-actions trend-actions");
 const group=(name,label)=>{
  const wrap=el("div","news-action-group news-action-"+name);
  wrap.setAttribute("role","group");wrap.setAttribute("aria-label",label);
  wrap.append(el("span","news-action-caption",label));actions.append(wrap);return wrap;
 };
 const publishing=group("publishing","Publicación");
 const editing=group("editing","Gestión y reelaboración");
 const artwork=group("artwork","Imagen");
 appendEditorialReButtons(editing,item);
 if(imageReady(item)||item.image_suppressed===true){
  const publicToggle=el("label","image-public-toggle");
  const switchInput=el("input");
  switchInput.type="checkbox";
  switchInput.setAttribute("role","switch");
  switchInput.checked=item.image_suppressed!==true&&item.public_image_visible!==false;
  switchInput.disabled=item.image_suppressed===true;
  switchInput.setAttribute("aria-label","Mostrar imagen IA de "+item.name+" en V1 pública");
  const switchText=el("span","image-public-label","Imagen en V1");
  publicToggle.title=item.image_sensitivity_default===true?
    "Tema sensible: imagen inicialmente oculta en V1 hasta tu autorización":"Solo afecta a la web pública V1; en V2 la imagen sigue visible";
  publicToggle.append(switchInput,switchText);
  if(item.image_sensitivity_default===true){
   const warning=el("small","image-sensitive-note","Sensible");
   warning.title="Precaución automática basada en el tema; puedes decidir mostrarla en V1";
   publicToggle.append(warning);
  }
  switchInput.addEventListener("change",async()=>{
   const visible=switchInput.checked;
   switchInput.disabled=true;
   try{
    const response=await fetch("/api/image-visibility",{method:"POST",credentials:"same-origin",
      headers:{"content-type":"application/json","x-ttv2-action":"1"},
      body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,scope:"public",visible})});
    if(!response.ok)throw Error("HTTP "+response.status);
    item.public_image_visible=visible;
    publishNotice("Imagen de «"+item.name+"»: "+(visible?"visible":"oculta")+" en V1. En V2 no cambia.");
    render();
   }catch(error){
    switchInput.checked=!visible;
    publishNotice("No se guardó la visibilidad pública de la imagen: "+error.message);
   }finally{switchInput.disabled=false;}
  });
  artwork.append(publicToggle);
  const hidden=item.image_suppressed===true;
  const visibility=el("button","publish-action image-visibility-action",hidden?"Restaurar IA":"Quitar IA");
  visibility.type="button";
  visibility.title=hidden?"Volver a mostrar la imagen en V2 y V1":"Ocultar esta imagen IA en V2 y V1 sin borrar el original";
  visibility.setAttribute("aria-label",(hidden?"Restaurar":"Quitar")+" imagen IA de "+item.name+" en las dos webs");
  visibility.addEventListener("click",async()=>{
   if(visibility.disabled)return;
   const message=hidden?"¿Restaurar la imagen IA de «"+item.name+"» en V2 y V1?":
     "¿Quitar la imagen IA de «"+item.name+"» de V2 y V1? La explicación seguirá visible y la imagen original se conservará por si decides restaurarla.";
   if(!window.confirm(message))return;
   visibility.disabled=true;
   try{
    const response=await fetch("/api/image-visibility",{method:"POST",credentials:"same-origin",
     headers:{"content-type":"application/json","x-ttv2-action":"1"},
     body:JSON.stringify({trend_id:item.trend_id,revision:item.revision,scope:"both",hidden:!hidden})});
    if(!response.ok)throw Error("HTTP "+response.status);
    item.image_suppressed=!hidden;
    if(!hidden)item.image_available=false;
    publishNotice((hidden?"Imagen restaurada":"Imagen retirada")+" en V2 y V1 para «"+item.name+"». La versión pública se actualizará con su siguiente consulta.");
    render();
    if(hidden)void refresh();
   }catch(error){
    visibility.disabled=false;
    publishNotice("No se pudo cambiar la imagen: "+error.message);
   }
  });
  artwork.append(visibility);
 }
 const x=el("button","publish-action","P-X");
 x.disabled=!publishableText(text);
 x.type="button";x.title="Preparar la publicación de texto en X";
 x.setAttribute("aria-label","Publicar texto en X para "+item.name);
 x.addEventListener("click",()=>{
  const link="https://twitter.com/intent/tweet?text="+encodeURIComponent(text);
  const opened=window.open(link,"_blank");
  if(opened)opened.opener=null;
  if(!opened)publishNotice("El navegador bloqueó la ventana de X. Permite abrir ventanas emergentes para publicar.");
 });
 publishing.append(x);
 if(!imageReady(item)&&item.image_suppressed!==true){
  const prompt=el('button','publish-action image-prompt-action','Copiar prompt IA');
  prompt.type='button';prompt.title='Copiar el prompt completo para generar un gag en un chat nuevo de ChatGPT';
  prompt.addEventListener('click',()=>{void copyManualImagePrompt(item).catch(error=>publishNotice(error.message))});
  artwork.append(prompt);
  const images=el('a','publish-action image-gpt-action','GPT IMA');
  images.href='https://chatgpt.com/images/';
  images.target='_blank';
  images.rel='noopener noreferrer';
  images.title='Abrir ChatGPT Images. Copia antes el prompt IA si quieres generar el gag de esta tendencia.';
  images.setAttribute('aria-label','Abrir ChatGPT Images para '+item.name);
  artwork.append(images);
  const paste=el('button','publish-action image-paste-action','Pegar IA');
  paste.type='button';paste.title='Pegar el original de Mis imágenes o seleccionarlo desde Fotos/Archivos';
  paste.addEventListener('click',()=>openManualPasteDialog(item));
  artwork.append(paste);
 }
 const pu=el("button","publish-action publication-mark-action","PU");
 pu.type="button";pu.title="Registrar una publicación realizada (contador móvil de 24 h)";
 pu.setAttribute("aria-label","Sumar una publicación de "+item.name+" al contador PU");
 pu.addEventListener("click",async()=>{
  if(pu.disabled)return;
  pu.disabled=true;
  try{
   const event_id=crypto.randomUUID();
   const response=await fetch("/api/publication-count",{method:"POST",credentials:"same-origin",
     headers:{"content-type":"application/json","x-ttv2-action":"1"},
     body:JSON.stringify({event_id,trend_id:item.trend_id,revision:item.revision})});
   if(!response.ok)throw Error("HTTP "+response.status);
   const data=await response.json();
   if(!Number.isSafeInteger(data.count)||!Array.isArray(data.events))throw Error("Respuesta de PU no válida");
   state.publications=data;renderPublications();
   publishNotice("PU registrada para «"+item.name+"». Últimas 24 h: "+data.count+".");
  }catch(error){publishNotice("No se pudo registrar PU para «"+item.name+"»: "+error.message)}
  finally{pu.disabled=false;}
 });
 publishing.append(pu);
 if(imageReady(item)){
  const withImage=el("button","publish-action publish-with-image","P-IA");
  withImage.disabled=!publishableText(text);
  withImage.type="button";withImage.title="Compartir en X con la imagen IA original";
  withImage.setAttribute("aria-label","Preparar publicación con imagen IA para "+item.name);
  withImage.addEventListener("click",async()=>{
   if(withImage.disabled)return;
   withImage.disabled=true;
   // Opening before any await avoids the pop-up blocker on desktop.
   const composer=typeof navigator.share!=="function"?window.open("about:blank","_blank"):null;
   if(composer)composer.opener=null;
   try{
    const endpoint=item.manual_image_url||"/api/image/"+encodeURIComponent(item.trend_id)+"?revision="+item.revision;
    const res=await fetch(endpoint,{credentials:"same-origin",cache:"no-store"});
    if(!res.ok)throw Error("Imagen no disponible (HTTP "+res.status+")");
    const blob=await res.blob();
    if(!["image/png","image/jpeg","image/webp"].includes(blob.type))throw Error("Formato de imagen no válido");
    const ext={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}[blob.type];
    const file=new File([blob],item.trend_id+"-r"+item.revision+"."+ext,{type:blob.type});
    if(navigator.canShare?.({files:[file]})&&navigator.share){
     await navigator.share({text,files:[file]});
    }else{
     // X intents cannot attach an image. Download the original for manual
     // attachment, then prepare the exact text in X's composer.
     const anchor=document.createElement("a");
     const local=URL.createObjectURL(blob);
     anchor.href=local;anchor.download=file.name;document.body.append(anchor);anchor.click();anchor.remove();
     setTimeout(()=>URL.revokeObjectURL(local),60000);
     const link="https://twitter.com/intent/tweet?text="+encodeURIComponent(text);
     if(composer)composer.location.replace(link);
     const opened=composer||window.open(link,"_blank");
     if(opened)opened.opener=null;
     publishNotice(opened?"Imagen descargada. Adjunta el archivo en X antes de confirmar la publicación.":
       "Imagen descargada. Abre X y adjunta el archivo; el navegador bloqueó la ventana de X.");
    }
   }catch(error){
    if(composer)composer.close();
    if(error.name!=="AbortError")publishNotice("P-IA: "+error.message);
   }finally{withImage.disabled=false}
  });
  publishing.append(withImage);
 }
 card.append(actions);
}
function render(){
 const root=$("results");root.replaceChildren();
 for(const item of state.items){
  const reset=reResetPending(item);
  const card=el("details","trend");
  card.classList.toggle("marked-red",isMarked(item));
  card.open=state.open===item.trend_id;
  card.addEventListener("toggle",()=>{
   if(card.open){
    state.open=item.trend_id;
    for(const other of root.querySelectorAll("details.trend"))if(other!==card&&other.open)other.open=false;
   }else if(state.open===item.trend_id)state.open=null;
  });
  const head=el("summary","trend-head");
  const icon=el("span","status-icon "+(reset?"pendiente":item.status),"●");
  icon.setAttribute("aria-label",reset?"Nueva explicación pendiente":({explicada:"Explicada",pendiente:"Pendiente",en_elaboracion:"En elaboración",incidencia:"Incidencia",desestimada:"Desestimada"})[item.status]||"Estado desconocido");
  icon.title=icon.getAttribute("aria-label");
  const title=el("span","title-details");
  title.append(el("strong","name",item.name));
  if(reset){
   const note=el("span","review-state",item.re_in_progress?"En revisión · nueva explicación en preparación":"RE solicitada · reinicio pendiente");
   note.setAttribute("role","status");
   title.append(note);
  }
  const entered=top30Since(item);
  if(entered)title.append(entered);
  const time=reset?null:explanationTime(item);
  if(time)title.append(time);
  head.append(el("span","rank","T"+item.rank),title,movementIndicator({...item,_rankingMeta:state}),icon);
  card.append(head);
  const flag=el("button","red-toggle","R");
  flag.type="button";
  flag.setAttribute("aria-pressed",String(isMarked(item)));
  flag.setAttribute("aria-label",isMarked(item)?"Quitar marca roja de "+item.name:"Marcar en rojo "+item.name);
  flag.title=isMarked(item)?"Quitar marca roja":"Marcar en rojo";
  // The R must live inside <summary>: closed <details> hide other children.
  // Cancel summary's default click action so R never expands/collapses the card.
  flag.addEventListener("click",event=>{
   event.preventDefault();
   event.stopPropagation();
   void toggleRedMark(item,card,flag);
  });
  head.append(flag);
  // Acción independiente del estado editorial: no envía ni publica nada.
  const busX=el("a","bus-x-link","BUS-X");
  busX.href="https://x.com/search?q="+encodeURIComponent(item.name)+"&f=live";
  busX.target="_blank";
  busX.rel="noopener noreferrer";
  busX.title="Buscar «"+item.name+"» en X (publicaciones recientes)";
  busX.setAttribute("aria-label",busX.title);
  busX.addEventListener("click",event=>event.stopPropagation());
  head.append(busX);
  if(!reset&&item.status==="explicada"&&item.image_in_progress===true
     &&!imageReady(item)&&item.image_suppressed!==true){
   const generating=el("span","image-working-icon","▧");
   generating.title="Imagen IA en elaboración";
   generating.setAttribute("aria-label",generating.title);
   generating.setAttribute("role","img");
   head.append(generating);
  }
  if(!reset&&(imageReady(item)||item.image_suppressed===true)){
   const photo=el("span","image-ready-icon","▣");
   photo.title=item.image_suppressed===true?"Imagen IA conservada pero retirada de las dos webs":"Imagen IA asociada a esta revisión";
   photo.setAttribute("aria-label",photo.title);
   head.append(photo);
   if(item.image_suppressed===true||item.public_image_visible===false){
    const hidden=el("span","image-ready-icon image-public-hidden-icon","▣");
    hidden.append(el("span","image-hidden-x","×"));
    hidden.title=item.image_suppressed===true?"Imagen IA retirada de V1 y V2":"Imagen IA oculta en V1; sigue disponible en V2";
    hidden.setAttribute("aria-label",hidden.title);
    head.append(hidden);
   }
  }
  const body=el("div","explanation",reset?(item.status==="explicada"?"Revisión editorial solicitada. Se preparará una nueva explicación e imagen.":item.status==="en_elaboracion"?"RE solicitada. El chat actual continúa; el próximo usará la nueva solicitud.":"RE solicitada. La nueva investigación está pendiente."):item.status==="explicada"?explanationText(item.explanation,item):({en_elaboracion:"En elaboración.",incidencia:"Incidencia en la elaboración.",desestimada:"Desestimada."})[item.status]||"Explicación pendiente.");
  card.append(body);
  if(!reset){const hint=imageRetryHint(item);if(hint)card.append(hint);}
  if(!reset&&!imageReady(item)&&item.image_suppressed!==true&&item.image_in_progress!==true)
   TTImageIncidents.attach({card,head,project:"ttendencias-v2",id:item.trend_id,revision:item.revision,available:item.image_incident_available===true});
  if(!reset||item.status!=="explicada")makePublishButtons(card,item);
  if(!reset)attachGeneratedImage(card,item);
  root.append(card);
 }
}
async function refresh(){
 if(new URLSearchParams(location.search).get("view")==="noticias")return;
 if(refreshing)return;
 const button=$("refresh");refreshing=true;button.disabled=true;button.classList.add("loading-refresh");
 try{
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),15000);
  let response;
  try{response=await fetch(BASE+"web-top30.json?v="+Date.now(),{cache:"no-store",signal:controller.signal})}
  finally{clearTimeout(timer)}
  if(!response.ok)throw Error("HTTP "+response.status);
  const data=valid(await response.json());
  state.items=data.items.slice().sort((a,b)=>a.rank-b.rank);
  state.captured=data.captured_at;
  state.rankingUnchanged=data.ranking_unchanged===true;
  state.rankingChangeAt=typeof data.ranking_change_at==="string"?data.ranking_change_at:null;
  if(state.open&&!state.items.some(item=>item.trend_id===state.open))state.open=null;
  await loadSharedMarks();
  try{await loadReRequests()}catch{state.reRequests=[]}
  try{await loadIncidentRequests()}catch{state.incidentRequests=[]}
  try{await loadIncidentRetryRequests()}catch{state.incidentRetryRequests=[]}
  try{await loadPublications()}catch{$("publication-summary").textContent="PU · — / 24 h"}
  try{await loadManualImages()}catch{}
  applyManualImages();
  render();
  $("notice").hidden=true;
  button.title="Actualizar tendencias · última consulta "+new Intl.DateTimeFormat("es-ES",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Madrid"}).format(new Date());
 }catch(error){
  $("notice").textContent="No se pudieron actualizar las tendencias. "+error.message;
  $("notice").hidden=false;
  if(!state.items.length)$("results").replaceChildren(el("p","loading","Sin datos disponibles."));
 }finally{refreshing=false;button.disabled=false;button.classList.remove("loading-refresh")}
}
$("refresh").addEventListener("click",refresh);
$("publication-summary").addEventListener("click",()=>{$("publication-dialog").showModal();void loadPublications().catch(()=>{})});
addEventListener("ttv2:publication-recorded",()=>void loadPublications().catch(()=>{}));
$("publication-close").addEventListener("click",()=>$("publication-dialog").close());
refresh();
if(newsViewMode){
 $("publication-summary").textContent="PUB · — / 24 h";
 const note=$("publication-dialog").querySelector("p");
 if(note)note.textContent="Solo cuenta PUB (publicación manual confirmada). Quitar pasa a Archivo sin contar. Los PU anteriores se conservan durante 24 horas. Ninguna acción publica automáticamente.";
 void loadPublications().catch(()=>{$("publication-summary").textContent="PUB · — / 24 h"});
}
setInterval(()=>{if(!document.hidden)refresh()},90000);
setInterval(()=>{if(!document.hidden)void loadPublications().catch(()=>{})},60000);


