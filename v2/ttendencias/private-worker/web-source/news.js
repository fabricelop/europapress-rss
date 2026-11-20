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
 $("publication-summary").textContent="PU · — / 24 h";
 $("radar-time").textContent="Noticias · cargando…";
 $("refresh").title="Actualizar noticias";
 const initial=new URLSearchParams(location.search);
 const state={query:(initial.get("q")||"").slice(0,100),page:1,loading:false,controller:null};
 $("news-search").value=state.query;
 const node=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=String(text);return n;};
 const date=value=>{const d=new Date(value);return Number.isFinite(d.getTime())?new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"}).format(d):"Sin fecha";};
 const filter=$("news-filters");filter.replaceChildren(node("span","news-meta","Noticias del radar verificadas"));
 const publicSite="https://ttactualidad.rainyraven22.chatgpt.site/";
 const errorText={news_suppressed:"Esta noticia ya está suprimida.",news_already_published:"La noticia ya se ha registrado como publicada.",news_changed:"El registro ha cambiado. Actualiza la lista.",news_not_current:"La noticia ya no figura en la lista maestra.",method_not_allowed:"El servidor ha rechazado la solicitud de seguridad.",news_master_action_unavailable:"No se ha podido guardar el cambio. Inténtalo de nuevo."};
 async function action(item,choice){
  const question=choice==="suppress"?"¿Suprimir esta noticia de V1 y V2?":"¿Confirmas que ya has publicado esta noticia en X? Se sumará al contador de 24 horas y quedará marcada en rojo.";
  if(!confirm(question))return;
  try{
   const response=await fetch("/api/news-master-action",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({id:item.id,action:choice})});
   const result=await response.json();
   if(!response.ok)throw Error(errorText[result.error]||"No se pudo registrar la acción.");
   $("news-error").hidden=true;
   await refreshNews();
   if(choice==="published")void refreshPublications();
  }catch(error){$("news-error").textContent=error.message;$("news-error").hidden=false;}
 }
 async function refreshPublications(){
  try{const r=await fetch("/api/news-master-publications",{credentials:"same-origin",cache:"no-store"});if(!r.ok)return;
   const data=await r.json();if(Number.isSafeInteger(data.count))$("publication-summary").textContent="PU · "+data.count+" / 24 h";
  }catch{}
 }
 function render(data){
  $("radar-time").textContent="Último barrido · "+date(data.observed_at);
  if(Number.isSafeInteger(data.unmarked_since_last_red))dispatchEvent(new CustomEvent("ttv2:news-master-refreshed",{detail:{count:data.unmarked_since_last_red}}));
  const list=$("news-list");list.replaceChildren();
  $("news-count").textContent=data.total+" "+(data.total===1?"noticia":"noticias")+(state.query?" · coincidencias":"");
  if(!data.items.length)list.append(node("p","news-empty",state.query?"No hay coincidencias.":"Todavía no hay noticias que cumplan el filtro de fuentes."));
  for(const item of data.items){
   const card=node("article","news-card");const summary=node("div","news-card-head");
   if(item.marked_red)card.classList.add("marked-red");
   const heading=node("span","news-title-wrap");heading.append(node("strong","news-title",item.title));
   heading.append(node("span","news-meta","Verificada · "+date(item.verified_at)));
   if(item.marked_red)heading.append(node("span","news-marked-label","🔴 Marcada"));
   summary.append(heading);
   card.append(summary);
   const controls=node("div","news-actions");
   const remove=node("button","publish-action","SUPRIMIR");remove.type="button";remove.addEventListener("click",()=>void action(item,"suppress"));
   const red=node("button","publish-action news-red-mark",item.marked_red?"R 🔴":"R");
   red.type="button";red.title=item.marked_red?"Quitar marca roja":"Marcar esta noticia en rojo";
   red.setAttribute("aria-pressed",String(item.marked_red));
   if(item.marked_red){red.style.background="#8e2435";red.style.color="#fff";red.style.borderColor="#a92f44";}
   red.addEventListener("click",async()=>{
    red.disabled=true;
    try{const response=await fetch("/api/news-master-action",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","x-ttv2-action":"1"},body:JSON.stringify({id:item.id,action:"red",value:!item.marked_red})});
     const result=await response.json();
     if(!response.ok)throw Error(errorText[result.error]||"No se pudo actualizar la marca roja.");
     await refreshNews();
    }catch(error){$("news-error").textContent=error.message;$("news-error").hidden=false;red.disabled=false;}
   });
   const post=node("button","publish-action","P-X");post.type="button";post.disabled=!!item.published_at;
   post.title="Abrir X con la noticia preparada; confirma la publicación allí";
   post.addEventListener("click",()=>{
    const caption=item.title.slice(0,280-publicSite.length-1)+" "+publicSite;
    window.open("https://twitter.com/intent/tweet?text="+encodeURIComponent(caption),"_blank","noopener,noreferrer");
   });
   const published=node("button","publish-action",item.published_at?"PU ✓":"PU");
   published.type="button";published.disabled=!!item.published_at;
   published.title="Registrar una publicación ya realizada en X";
   published.addEventListener("click",()=>void action(item,"published"));
   controls.append(red,remove,post,published);card.append(controls);list.append(card);
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
   const qs=new URLSearchParams({q:state.query,page:String(state.page)});
   const response=await fetch("/api/news-master?"+qs,{credentials:"same-origin",cache:"no-store",signal:controller.signal});
   if(!response.ok)throw Error("No se pudo cargar la lista de noticias. Inténtalo de nuevo.");
   const data=await response.json();
   if(data.project!=="ttittulares-v2"||data.kind!=="master_news"||!Array.isArray(data.items))throw Error("La lista de noticias no está disponible.");
   if(state.controller!==controller)return;
   render(data);$("news-error").hidden=true;
  }catch(error){
   if(state.controller!==controller)return;
   $("news-error").textContent=error.name==="AbortError"?"La consulta ha tardado demasiado. Inténtalo de nuevo.":error.message;
   $("news-error").hidden=false;
   $("news-list").replaceChildren(node("p","news-empty","No se ha podido cargar la lista de noticias."));
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
 void refreshNews();void refreshPublications();
 setInterval(()=>{if(!document.hidden&&!state.loading){void refreshNews();void refreshPublications();}},90000);
})();
