"use strict";
(()=>{
 const active=new URLSearchParams(location.search).get("view")==="noticias";
 const $=id=>document.getElementById(id);
 $("nav-news").setAttribute("aria-current",active?"page":"false");
 $("nav-trends").setAttribute("aria-current",active?"false":"page");
 if(!active)return;
 document.title="TT · Noticias";
 document.body.classList.add("news-view");
 $("results").hidden=true;
 $("news-panel").hidden=false;
 $("publication-summary").hidden=true;
 $("radar-time").textContent="Noticias · cargando…";
 $("refresh").title="Actualizar noticias";
 $("refresh").setAttribute("aria-label","Actualizar noticias");
 const names={pending:"Pendientes",detected:"Detectadas",working:"En elaboración",ready:"Elaboradas",incident:"Incidencias",archived:"Archivo"};
 const state={data:null,page:1,filter:"pending",query:"",loading:false,controller:null};
 const node=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=String(text);return n;};
 function date(value){const d=new Date(value);return value&&Number.isFinite(d.getTime())?new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"}).format(d):"Hora no disponible";}
 function render(data){
  state.data=data;
  $("radar-time").textContent="Último barrido · "+date(data.observed_at);
  $("news-time").textContent="Los titulares proceden de las fuentes y aún no son una explicación editorial. Radar de entrada: pasadas puntuales.";
  const filters=$("news-filters");filters.replaceChildren();
  for(const [key,label] of Object.entries(names)){
   const b=node("button","news-filter",label+" · "+data.counts[key]);b.type="button";
   b.setAttribute("aria-pressed",String(state.filter===key));
   b.addEventListener("click",()=>{state.filter=key;state.page=1;void refreshNews();});filters.append(b);
  }
  const list=$("news-list");list.replaceChildren();
  $("news-count").textContent=data.total+" "+(data.total===1?"noticia":"noticias")+(state.query?" encontradas":"");
  if(!data.items.length)list.append(node("p","news-empty",state.query?"No hay noticias que coincidan con la búsqueda.":"Todavía no hay noticias en este estado."));
  for(const item of data.items){
   const card=node("details","news-card");
   const summary=node("summary","news-card-head");
   const heading=node("span","news-title-wrap");heading.append(node("strong","news-title",item.title));
   heading.append(node("span","news-meta","Detectada · "+date(item.first_seen_at)+" · "+item.source_family_count+" familias de fuentes"));
   summary.append(heading,node("span","news-status "+item.group,item.status_label));card.append(summary);
   const body=node("div","news-body");
   body.append(node("p","",item.group==="detected"?"Esperando cobertura de suficientes familias independientes antes de pasar a elaboración.":
    item.group==="pending"?"Pendiente de investigar, contrastar y redactar. Todavía no hay explicación editorial.":
    item.group==="working"?"La elaboración editorial está en curso.":item.group==="ready"?"La elaboración ha terminado; este apartado muestra por ahora el estado y las fuentes.":
    item.group==="incident"?"La noticia requiere revisar su estado antes de continuar.":item.status_label+"."));
   if(item.source_families.length){const sources=node("ul","news-sources");for(const source of item.source_families)sources.append(node("li","",source));body.append(sources);}
   if(item.source_url){
    try{const target=new URL(item.source_url);if(["https:","http:"].includes(target.protocol)&&!target.username&&!target.password){
     const link=node("a","news-source-link","Abrir noticia de origen ↗");link.href=target.href;link.target="_blank";link.rel="noopener noreferrer";body.append(link);
    }}catch{}
   }
   card.append(body);list.append(card);
  }
  $("news-page").textContent="Página "+data.page+" de "+data.pages;
  $("news-prev").disabled=data.page<=1;$("news-next").disabled=data.page>=data.pages;
  $("news-pagination").hidden=data.pages<=1;state.page=data.page;
 }
 async function refreshNews(){
  if(state.controller)state.controller.abort();
  const controller=new AbortController();state.controller=controller;state.loading=true;
  const button=$("refresh");button.disabled=true;button.classList.add("loading-refresh");
  $("news-list").setAttribute("aria-busy","true");
  const timeout=setTimeout(()=>controller.abort(),20000);
  try{
   const params=new URLSearchParams({state:state.filter,q:state.query,page:String(state.page)});
   const response=await fetch("/api/news?"+params,{credentials:"same-origin",cache:"no-store",signal:controller.signal});
   if(!response.ok)throw Error(response.status===401?"La sesión ha caducado. Vuelve a entrar.":"No se pudieron actualizar las noticias. Inténtalo de nuevo.");
   const data=await response.json();
   if(data.project!=="ttittulares-v2"||!Array.isArray(data.items)||!data.counts)throw Error("Los datos de noticias no están disponibles.");
   if(state.controller!==controller)return;
   render(data);$("news-error").hidden=true;
  }catch(error){
   if(state.controller!==controller)return;
   $("news-error").textContent=error.name==="AbortError"?"La consulta ha tardado demasiado. Inténtalo de nuevo.":error.message;
   $("news-error").hidden=false;
   if(!state.data)$("news-list").replaceChildren(node("p","news-empty","No se ha podido cargar la lista de noticias."));
  }finally{
   clearTimeout(timeout);
   if(state.controller===controller){state.controller=null;state.loading=false;button.disabled=false;button.classList.remove("loading-refresh");$("news-list").setAttribute("aria-busy","false");}
  }
 }
 let timer;
 $("news-search").addEventListener("input",()=>{clearTimeout(timer);timer=setTimeout(()=>{state.query=$("news-search").value.trim();state.page=1;void refreshNews();},350);});
 $("news-prev").addEventListener("click",()=>{state.page--;void refreshNews();});
 $("news-next").addEventListener("click",()=>{state.page++;void refreshNews();});
 $("refresh").addEventListener("click",()=>void refreshNews());
 void refreshNews();
 setInterval(()=>{if(!document.hidden&&!state.loading)void refreshNews();},90000);
})();
