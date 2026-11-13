"use strict";
const BASE="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/state/";
const $=id=>document.getElementById(id);
const state={items:[],captured:null,open:new Set()};
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
   out.push(line.replace(/^Hashtags:\s*/i,"").replace(/^Remate:\s*/i,""));
   if(line.includes("🌶"))break;
  }
  const value=out.join("\n").trim();
  if(hasProse&&value.length>60)return value;
 }
 return "Explicación capturada; formato editorial pendiente de adaptar.";
}
function render(){const root=$("results");root.replaceChildren();for(const item of state.items){const card=el("details","trend");card.open=state.open.has(item.trend_id);card.addEventListener("toggle",()=>{if(card.open)state.open.add(item.trend_id);else state.open.delete(item.trend_id)});const head=el("summary","trend-head");const icon=el("span","status-icon "+item.status,({explicada:"●",pendiente:"●",en_elaboracion:"●",incidencia:"●",desestimada:"●"})[item.status]||"●");icon.setAttribute("aria-label",({explicada:"Explicada",pendiente:"Pendiente",en_elaboracion:"En elaboración",incidencia:"Incidencia",desestimada:"Desestimada"})[item.status]||"Estado desconocido");icon.title=icon.getAttribute("aria-label");head.append(el("span","rank","T"+item.rank),el("strong","name",item.name),icon);card.append(head);const body=el("div","explanation",item.status==="explicada"?editorial(item.explanation):({en_elaboracion:"En elaboración.",incidencia:"Incidencia en la elaboración.",desestimada:"Desestimada."})[item.status]||"Explicación pendiente.");card.append(body);root.append(card)}}
async function refresh(){try{const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),15000);let response;try{response=await fetch(BASE+"web-top30.json?v="+Math.floor(Date.now()/60000),{cache:"no-store",signal:controller.signal})}finally{clearTimeout(timer)}if(!response.ok)throw Error("HTTP "+response.status);const data=valid(await response.json());state.items=data.items.slice().sort((a,b)=>a.rank-b.rank);state.captured=data.captured_at;render();$("notice").hidden=true}catch(error){$("notice").textContent="No se pudieron actualizar las tendencias. "+error.message;$("notice").hidden=false;if(!state.items.length)$("results").replaceChildren(el("p","loading","Sin datos disponibles."))}}
refresh();setInterval(()=>{if(!document.hidden)refresh()},90000);
