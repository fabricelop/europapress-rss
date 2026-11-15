"use strict";
const BASE="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/state/";
const $=id=>document.getElementById(id);
const state={items:[],captured:null,open:null,rankingUnchanged:false,rankingChangeAt:null};
function el(tag,className,content){const n=document.createElement(tag);if(className)n.className=className;if(content!==undefined)n.textContent=String(content);return n}
function valid(data){if(!data||data.project!=="ttactualidad-v2"||data.country!=="ES"||!Array.isArray(data.items)||data.items.length!==data.count||data.count<1||data.count>40)throw Error("Ranking no disponible");const ranks=new Set(data.items.map(x=>x.rank));if(ranks.size!==data.items.length||data.items.some(x=>!Number.isInteger(x.rank)||x.rank<1||x.rank>40||!x.name))throw Error("Ranking incoherente");return data}
function editorial(raw){
 if(typeof raw!=="string"||!raw.trim())return "Explicación pendiente.";
 const s=raw.replace(/\r\n/g,"\n"), lines=s.split("\n");
 const anchors=[/^\s*(?:Texto(?: editorial| propuesto)? para LISTAS|Explicaci[oó]n para LISTAS|Explicaci[oó]n editorial|Explicaci[oó]n period[ií]stica(?: para LISTAS)?|Texto para LISTAS)\s*:?\s*$/i];
 const indices=[];for(let i=0;i<lines.length;i++)if(anchors.some(r=>r.test(lines[i])))indices.push(i);
 const candidates=indices.length?indices.reverse():[0];
 for(const from of candidates){
  let out=[],started=false,hasProse=false;
  for(let i=from+1;i<Math.min(lines.length,from+22);i++){
   const line=lines[i].trim();
   if(!line){if(started&&out[out.length-1]!=="")out.push("");continue}
   if(/^(?:Writing|Standard|Document|Texto editorial|Causa confirmada|Causa predominante acreditada)$/i.test(line))continue;
   if(/^(?:Contraste cronol[oó]gico|Fuentes verificadas|Fuentes consultadas|Fuentes y contraste|Control editorial|Conclusi[oó]n|Resultado(?: editorial| de la prueba)?|Presencia de la tendencia|L[ií]mite:|La causa est[aá]|La coincidencia temporal|Verificaci[oó]n|Referencias|Notas de cautela|Contexto y fuentes|Cronolog[ií]a|Justificaci[oó]n|Contexto adicional)/i.test(line))break;
   if(/^https?:\/\//i.test(line)||/^www\./i.test(line))break;
   if(/^(?:Tendencia:|Identificador:|Revisi[oó]n:|ESTADO_|ID:|Fecha:|Ficha editorial)/i.test(line))continue;
   if(!started&&line.length<40&&!line.startsWith("#")&&!/^(?:TT#|🌶)/u.test(line))continue;
   if(line.length>70)hasProse=true;
   started=true;
   out.push(line.replace(/^Hashtags:\s*/i,"").replace(/^(?:Remate|Chiste)(?:\s+[^:]{1,35})?:\s*/iu,""));
   if(line.includes("🌶"))break;
  }
  const value=out.join("\n").trim();
  if(hasProse&&value.length>60)return value;
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
function tweetText(raw,item){
 const source=editorial(raw);
 if(source.startsWith("Explicación pendiente")||source.startsWith("Explicación capturada"))return source;
 const rank=Number.isInteger(item?.rank)?item.rank:0;
 const name=String(item?.name||"TENDENCIA").toLocaleUpperCase("es-ES").trim();
 const prefix="TT#"+rank+" "+name+" es tendencia";
 const lines=source.split("\n").map(x=>x.trim()).filter(Boolean);
 const jokeLine=lines.find(x=>x.includes("🌶"))||"";
 // Las etiquetas editoriales son metadatos, no texto publicable.\n const joke=jokeLine.replace(/^(?:Remate|Chiste)(?:\s+[^:]{1,35})?:\s*/iu,"").trim();
 const hashLine=lines.filter(x=>!x.includes("🌶")&&(/^(?:Hashtags:\s*)?#\S+/i.test(x)||/^Hashtags:\s*#/i.test(x))).map(x=>x.replace(/^Hashtags:\s*/i,"").trim()).join(" ");
 const hashes=[...new Set((hashLine.match(/#[\p{L}\p{N}_]+/gu)||[]))].join(" ");
 let prose=lines.filter(x=>!x.includes("🌶")&&!/^Hashtags:\s*/i.test(x)&&!/^\s*#[\p{L}\p{N}_]+(?:\s+#[\p{L}\p{N}_]+)*\s*$/u.test(x)).join(" ").replace(/\s+/g," ").trim();
 // Remove an already written lead only if it is the same trend and prefix.
 prose=prose.replace(/^TT#\d+\s+/iu,"");
 const lead=name+" ES TENDENCIA";
 if(prose.toLocaleUpperCase("es-ES").startsWith(lead))
  prose=prose.slice(lead.length).replace(/^\s*[:,]?\s*/u,"");
 // Preserve grammatical meaning when the raw text begins with its own trend name.
 else if(prose.toLocaleUpperCase("es-ES").startsWith(name+" ")){
  const rest=prose.slice(name.length).trim();
  prose=/^(?:por|porque|tras|ante|debido|en |al |a raíz)/iu.test(rest)?rest:"porque "+rest;
 }
 if(!prose)return prefix+".";
 const explanation=completeProse(prose,280-xLength(prefix)-2);
 if(!explanation)return prefix+". Consulta la explicación íntegra en la ficha.";
 // Explicit priority: A explanation, B full punchline, C whole tags, D URL.
 const parts=[prefix+(/^(?:porque |por |tras |ante |debido |en |al |a raíz)/iu.test(explanation)?" ":": ")+explanation];
 for(const component of [joke,hashes,WEB_URL]){
  if(component&&xLength(parts.join("\n")+"\n"+component)<=280)parts.push(component);
 }
 return parts.join("\n");
}
// Server-side marks: same state on every authenticated browser and device.
let redMarks={};
let refreshing=false;
function markStamp(item){return typeof item.entered_top30_at==="string"?item.entered_top30_at:""}
function isMarked(item){return redMarks[item.trend_id]===markStamp(item)&&!!markStamp(item)}
async function loadSharedMarks() {
 const res=await fetch("/api/marks",{cache:"no-store",credentials:"same-origin"});
 if(!res.ok)throw Error("No se pueden sincronizar las marcas R (HTTP "+res.status+")");
 const data=await res.json();
 if(!data.marks||typeof data.marks!=="object")throw Error("Respuesta de marcas no válida");
 redMarks=data.marks;
}
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
 }catch{
  $("notice").textContent="No se ha guardado la marca R. Comprueba la conexión e inténtalo de nuevo.";
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
 }else if(["entry","reentry","short_return"].includes(item.movement)){
  label="Nueva";description="Entra o regresa al Top 30";kind="entry";
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
 const node=el("time","entered-top30","Desde "+stamp);
 node.dateTime=item.entered_top30_at;
 node.title="Entrada en el Top 30: "+stamp+" (hora peninsular)";
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
   picture.src="/api/image/"+encodeURIComponent(item.trend_id)+"?revision="+item.revision;
  };
  card.addEventListener("toggle",openImage);
  openImage();
}
function imageReady(item){
 return item.image_available===true&&item.status==="explicada"&&
   /^trv2-[a-f0-9]{24}$/.test(item.trend_id)&&
   Number.isSafeInteger(item.revision)&&item.revision>=1;
}
function publishNotice(message){
 const notice=$("notice");notice.textContent=message;notice.hidden=false;
}
function makePublishButtons(card,item){
 if(item.status!=="explicada")return;
 const text=tweetText(item.explanation,item);
 if(text.startsWith("Explicación pendiente"))return;
 const actions=el("div","publish-actions");
 const x=el("button","publish-action","P-X");
 x.type="button";x.title="Preparar la publicación de texto en X";
 x.setAttribute("aria-label","Publicar texto en X para "+item.name);
 x.addEventListener("click",()=>{
  const link="https://twitter.com/intent/tweet?text="+encodeURIComponent(text);
  const opened=window.open(link,"_blank");
  if(opened)opened.opener=null;
  if(!opened)publishNotice("El navegador bloqueó la ventana de X. Permite abrir ventanas emergentes para publicar.");
 });
 actions.append(x);
 if(imageReady(item)){
  const withImage=el("button","publish-action publish-with-image","P-IA");
  withImage.type="button";withImage.title="Compartir en X con la imagen IA original";
  withImage.setAttribute("aria-label","Preparar publicación con imagen IA para "+item.name);
  withImage.addEventListener("click",async()=>{
   if(withImage.disabled)return;
   withImage.disabled=true;
   // Opening before any await avoids the pop-up blocker on desktop.
   const composer=typeof navigator.share!=="function"?window.open("about:blank","_blank"):null;
   if(composer)composer.opener=null;
   try{
    const endpoint="/api/image/"+encodeURIComponent(item.trend_id)+"?revision="+item.revision;
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
  actions.append(withImage);
 }
 card.append(actions);
}
function render(){
 const root=$("results");root.replaceChildren();
 for(const item of state.items){
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
  const icon=el("span","status-icon "+item.status,"●");
  icon.setAttribute("aria-label",({explicada:"Explicada",pendiente:"Pendiente",en_elaboracion:"En elaboración",incidencia:"Incidencia",desestimada:"Desestimada"})[item.status]||"Estado desconocido");
  icon.title=icon.getAttribute("aria-label");
  const title=el("span","title-details");
  title.append(el("strong","name",item.name));
  const entered=top30Since(item);
  if(entered)title.append(entered);
  const time=explanationTime(item);
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
  if(imageReady(item)){
   const photo=el("span","image-ready-icon","▣");
   photo.title="Imagen IA asociada a esta revisión";
   photo.setAttribute("aria-label",photo.title);
   head.append(photo);
  }
  const body=el("div","explanation",item.status==="explicada"?tweetText(item.explanation,item):({en_elaboracion:"En elaboración.",incidencia:"Incidencia en la elaboración.",desestimada:"Desestimada."})[item.status]||"Explicación pendiente.");
  card.append(body);
  makePublishButtons(card,item);
  attachGeneratedImage(card,item);
  root.append(card);
 }
}
async function refresh(){
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
refresh();
setInterval(()=>{if(!document.hidden)refresh()},90000);
