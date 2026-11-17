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
 $("publication-summary").hidden=false;
 $("publication-summary").textContent="PUB · — / 24 h";
 $("radar-time").textContent="Noticias · cargando…";
 $("refresh").title="Actualizar noticias";
 $("refresh").setAttribute("aria-label","Actualizar noticias");
 const names={ready:"Elaboradas",pending:"Pendientes",detected:"Detectadas",working:"En elaboración",incident:"Incidencias",archived:"Archivo"};
 const short={ready:"Elab.",pending:"Pend.",detected:"Det.",working:"Curso",incident:"Inc.",archived:"Arch."};
 const state={data:null,page:1,filter:"ready",query:"",loading:false,controller:null,open:null,records:new Map()};
 const node=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=String(text);return n;};
 function date(value){const d=new Date(value);return value&&Number.isFinite(d.getTime())?new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"}).format(d):"Hora no disponible";}
 function render(data){
  state.data=data;
  $("radar-time").textContent="Último barrido · "+date(data.observed_at)+
   (data.radar_delayed?" · "+data.radar_age_minutes+" min sin actualizar":"")+
   (data.radar_independent&&data.editorial_delayed?" · Elaboraciones pendientes de sincronizar ("+data.editorial_age_minutes+" min)":"");
  const filters=$("news-filters");filters.replaceChildren();
  for(const [key,label] of Object.entries(names)){
   const b=node("button","news-filter",short[key]+" "+data.counts[key]);b.type="button";b.title=label;b.setAttribute("aria-label",label+" · "+data.counts[key]);
   b.setAttribute("aria-pressed",String(state.filter===key));
   b.addEventListener("click",()=>{state.filter=key;state.page=1;state.open=null;void refreshNews();});filters.append(b);
  }
  const list=$("news-list");list.replaceChildren();
  $("news-count").textContent=data.total+" "+(data.total===1?"noticia":"noticias")+(state.query?" · coincidencias":"");
  if(!data.items.length)list.append(node("p","news-empty",state.query?"No hay noticias que coincidan con la búsqueda.":"Todavía no hay noticias en este estado."));
  for(const item of data.items){
   const card=node("details","news-card");
   const summary=node("summary","news-card-head");
   const heading=node("span","news-title-wrap");heading.append(node("strong","news-title",item.title));
   heading.append(node("span","news-meta","Detectada · "+date(item.first_seen_at)+" · "+item.source_family_count+" familias de fuentes"));
   summary.append(heading,node("span","news-status "+item.group,item.status_label));
   if(item.has_image===true){
    const hidden=item.image_suppressed||item.public_image_visible===false;
    const imageIcon=node("span","news-image-head-icon"+(hidden?" news-image-head-hidden":""),"🖼️");
    imageIcon.title=item.image_suppressed?"Imagen generada, retirada":hidden?"Imagen generada, oculta en V1":"Imagen generada y asociada a esta noticia";
    imageIcon.setAttribute("aria-label",imageIcon.title);summary.append(imageIcon);
   }else if(item.image_in_progress===true&&item.group==="ready"){
    const imageIcon=node("span","news-image-head-icon news-image-head-progress","🎨");
    imageIcon.title="Imagen en elaboración; todavía no está asociada";
    imageIcon.setAttribute("aria-label",imageIcon.title);summary.append(imageIcon);
   }
   card.append(summary);
   const body=node("div","news-body");
   const explanation=node("p",item.group==="ready"?"news-tweet":"",item.group==="detected"?"Esperando cobertura de suficientes familias independientes antes de pasar a elaboración.":
    item.group==="pending"?"Pendiente de investigar, contrastar y redactar. Todavía no hay explicación editorial.":
    item.group==="working"?"La elaboración editorial está en curso.":item.group==="ready"?"Cargando explicación…":
    item.group==="incident"?"La noticia requiere revisar su estado antes de continuar.":item.status_label+".");body.append(explanation);
   if(item.source_families.length){const sources=node("ul","news-sources");for(const source of item.source_families)sources.append(node("li","",source));body.append(sources);}
   if(item.source_url){
    try{const target=new URL(item.source_url);if(["https:","http:"].includes(target.protocol)&&!target.username&&!target.password){
     const link=node("a","news-source-link","Abrir noticia de origen ↗");link.href=target.href;link.target="_blank";link.rel="noopener noreferrer";body.append(link);
    }}catch{}
   }
   card.append(body);
   TTImageIncidents.attach({card,head:summary,project:"ttittulares-v2",id:item.event_id,revision:item.revision,available:item.image_incident_available===true});
   list.append(card);
   let loaded=false;
   const loadRecord=async()=>{
    if(loaded||!["ready","archived"].includes(item.group))return;loaded=true;
    try{
     const key=item.event_id+":"+item.revision;
     let record=state.records.get(key);
     if(!record){const response=await fetch("/api/news/"+encodeURIComponent(item.event_id)+"?revision="+item.revision,{credentials:"same-origin",cache:"no-store",signal:AbortSignal.timeout(20000)});if(!response.ok)throw Error("record_unavailable");record=await response.json();}
     if(record.event_id!==item.event_id||record.revision!==item.revision||typeof record.tweet_text!=="string"||record.x_character_count>280)throw Error("record_invalid");
     state.records.set(key,record);explanation.textContent=record.tweet_text;
     TTNewsActions.attach({item,card,head:summary,body,record,onChange:refreshNews});
     explanation.after(node("p","news-tweet-count",record.x_character_count+" / 280"));
    }catch{loaded=false;explanation.textContent="No se pudo cargar la explicación de esta revisión. Cierra y vuelve a abrir la noticia para reintentar.";}
   };
   card.open=state.open===item.event_id;
   card.addEventListener("toggle",()=>{if(card.open){state.open=item.event_id;for(const other of list.querySelectorAll("details.news-card"))if(other!==card)other.open=false;void loadRecord();}else if(state.open===item.event_id)state.open=null;});
   if(card.open)void loadRecord();
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


