"use strict";
window.TTNewsActions=(()=>{
 const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
 const notice=message=>{const n=document.getElementById("news-error");n.textContent=message;n.hidden=false;};
 const endpoint=item=>"/api/news-image?id="+item.event_id+"&revision="+item.revision;
 const weighted=text=>text.replace(/https?:\/\/\S+/gu,"X".repeat(23)).length;
 function tweet(record){const text=record.tweet_text.trim(),url="https://ttactualidad.rainyraven22.chatgpt.site/";return weighted(text+"\n"+url)<=280?text+"\n"+url:text;}
 function attachPublicImageToggle(item,artwork,onChange){
  const label=el("label","image-public-toggle"),toggle=el("input");toggle.type="checkbox";
  toggle.checked=item.public_image_visible===true;
  toggle.disabled=item.image_suppressed===true;toggle.setAttribute("role","switch");
  toggle.setAttribute("aria-label","Mostrar imagen en V1");
  toggle.addEventListener("change",async()=>{toggle.disabled=true;
   try{await action(item,"public_image",toggle.checked);await onChange();}
   catch(error){toggle.checked=!toggle.checked;notice(error.message);}
   finally{toggle.disabled=item.image_suppressed===true;}
  });
  label.append(toggle,el("span","image-public-label","Imagen en V1"));artwork.append(label);
 }
 async function action(item,type,value,hints){
  let response;
  try{
   response=await fetch("/api/news-actions",{method:"POST",credentials:"same-origin",
    headers:{"content-type":"application/json","x-ttv2-action":"1"},
    signal:AbortSignal.timeout(18000),
    body:JSON.stringify({action_id:crypto.randomUUID().replaceAll("-",""),event_id:item.event_id,
     revision:item.revision,action:type,...(value!==undefined?{value}:{}),...(hints?{hints}:{})})});
  }catch(error){
   if(error.name==="AbortError"||error.name==="TimeoutError")
    throw Error("La solicitud tardó demasiado. Actualiza la lista para comprobar si se guardó antes de pulsar otra vez.");
   throw error;
  }
  if(!response.ok){
   const result=await response.json().catch(()=>({}));
   const explanations={
    news_retry_requires_environment_repair:"El reintento está bloqueado por un problema del navegador, credenciales o disco.",
    news_incident_unavailable_or_stale:"La incidencia ha cambiado o su registro aún no está sincronizado. Actualiza la lista.",
    news_incident_queue_unavailable:"No se pudo comprobar la cola de incidencias. Reintenta tras actualizar.",
    news_incident_already_dismissed:"Esta noticia ya fue suprimida. Actualiza la lista.",
    news_retry_already_requested:"El reintento ya está registrado. Actualiza la lista.",
    news_preferences_changed:"La noticia se ha modificado mientras pulsabas. Actualiza la lista.",
    news_action_unavailable:"El servidor no ha podido completar la acción. Vuelve a consultar el estado."
   };
   throw Error(explanations[result.error]||
    (response.status===409?"La noticia ha cambiado o ya se está procesando. Actualiza la lista.":"No se pudo guardar la acción (HTTP "+response.status+")."));
  }
  return response.json();
 }
 function attachPending({item,body,onChange}){
  if(item.group!=="pending"||body.querySelector(".news-pending-actions"))return;
  const actions=el("div","news-actions news-pending-actions");
  actions.setAttribute("role","group");actions.setAttribute("aria-label","Acciones sobre noticia pendiente");
  const dismiss=el("button","publish-action news-pending-dismiss","Suprimir");
  const urgent=el("button","publish-action news-pending-urgent",item.urgent_requested?"URGENTE ✓":"URGENTE");
  dismiss.type=urgent.type="button";
  dismiss.title="Archivar esta noticia sin elaborar ni publicar";
  urgent.title="Prioridad para el próximo hueco disponible; no interrumpe chats abiertos";
  urgent.disabled=item.urgent_requested===true;
  const wire=(button,type)=>button.addEventListener("click",async event=>{
   event.preventDefault();event.stopPropagation();
   if(button.disabled)return;
   if(type==="dismiss"&&!confirm("¿Suprimir esta noticia pendiente? Pasará a Archivo como «Suprimida», sin elaborar ni publicar."))return;
   dismiss.disabled=urgent.disabled=true;
   try{await action(item,type);await onChange(type==="dismiss"?"archived":"pending",item);}
   catch(error){notice(error.message);dismiss.disabled=false;urgent.disabled=item.urgent_requested===true;}
  });
  wire(dismiss,"dismiss");wire(urgent,"urgent");actions.append(dismiss,urgent);body.append(actions);
 }
 function prompt(item,record){return 'TTN2_IMAGE_JOB_V1 '+JSON.stringify({event_id:item.event_id,revision:item.revision})+
  "\nGenera UNA imagen original con ImageGen de mínimo 1024px. Cómic editorial europeo con una escena narrativa, protagonistas, acción clara, profundidad, luz y textura. Sin texto, titulares, hashtags, logos, diagramas ni collage. Una metáfora visual del hecho contrastado. En sucesos graves, escena contextual seria y respetuosa sin humor contra víctimas. Chat nuevo e independiente; no abras el chat editorial.\n"+
  record.title+"\n"+record.factual_summary+"\n"+record.tweet_text;}
 function attachIncident({item,body,onChange}){
  if(item.group!=="incident"||item.status_label!=="Incidencia de elaboración"||body.querySelector(".news-incident-actions"))return;
  const actions=el("div","news-actions news-incident-actions");
  actions.setAttribute("role","group");actions.setAttribute("aria-label","Acciones sobre la noticia con incidencia");
  const retry=el("button","publish-action news-incident-retry","↻ Reintentar");
  const dismiss=el("button","publish-action news-incident-dismiss","Suprimir");
  for(const button of [retry,dismiss])button.type="button";
  retry.title="Nueva revisión y nuevo chat editorial desde cero; los intentos anteriores se conservan";
  dismiss.title="Retirar la noticia de todas las listas visibles, conservando el historial interno";
  const wire=(button,type,confirmText)=>button.addEventListener("click",async event=>{
   event.preventDefault();event.stopPropagation();if(button.disabled)return;
   if(confirmText&&!confirm(confirmText))return;
   retry.disabled=dismiss.disabled=true;
   const previousLabel=button.textContent;
   button.textContent=type==="dismiss"?"Suprimiendo…":"Solicitando…";
   let accepted=false;
   try{
    await action(item,type);
    accepted=true;
    button.textContent=type==="dismiss"?"Suprimida ✓":"Reintento solicitado ✓";
    await onChange(item);
   }catch(error){
    if(accepted)notice("La orden se ha guardado, pero la lista no se ha podido actualizar. Pulsa Actualizar.");
    else{notice(error.message);retry.disabled=dismiss.disabled=false;button.textContent=previousLabel;}
   }
  });
  wire(retry,"retry_editorial");
  wire(dismiss,"dismiss","¿Suprimir esta noticia de INC? Desaparecerá de las listas, incluido Archivo. Se conservará el historial interno y no volverá a elaborarse automáticamente.");
  actions.append(retry,dismiss);body.append(actions);
 }
 function attach({item,card,head,body,record,onChange}){
  if(body.querySelector(".news-actions"))return;
  // The V1/public switch must never hide an authorized image in private V2.
  if(item.image_available){
   const image=el("img","news-original");image.src=endpoint(item);image.alt="Ilustración editorial de "+item.title;image.loading="lazy";body.prepend(image);
   if(item.public_image_visible===false)image.after(el("p","news-image-working","Imagen visible aquí en V2; oculta en la web V1."));
  }else if(item.image_in_progress){body.append(el("p","news-image-working","▧ Imagen IA en elaboración"));}
  if(item.group==="archived"&&item.status_label!=="Suprimida"){
   // ARCH keeps the same V1-only switch as ELAB, without offering a second
   // publication or rework action on a finished record.
   if(item.has_image===true){
    const actions=el("div","news-actions"),artwork=el("div","news-action-group news-action-artwork");
    artwork.setAttribute("role","group");artwork.setAttribute("aria-label","Imagen");
    artwork.append(el("span","news-action-caption","Imagen"));
    attachPublicImageToggle(item,artwork,onChange);actions.append(artwork);body.append(actions);
   }
   return;
  }
  if(item.group!=="ready")return;
  card.classList.toggle("marked-red",item.marked===true);
  const actions=el("div","news-actions");
  const group=(name,label)=>{
   const wrap=el("div","news-action-group news-action-"+name);
   wrap.setAttribute("role","group");wrap.setAttribute("aria-label",label);
   wrap.append(el("span","news-action-caption",label));actions.append(wrap);return wrap;
  };
  const publishing=group("publishing","Publicación");
  const editing=group("editing","Gestión y reelaboración");
  const artwork=group("artwork","Imagen");
  const add=(label,title,handler,target=editing)=>{
   const b=el("button","publish-action",label);b.type="button";b.title=title;
   b.addEventListener("click",async event=>{event.preventDefault();event.stopPropagation();if(b.disabled)return;b.disabled=true;
    try{await handler();}catch(error){if(error.name!=="AbortError")notice(error.message);}finally{b.disabled=false;}});
   target.append(b);return b;
  };
  add("P-X","Abrir el editor de X con el texto; no publica automáticamente",()=>{
   const opened=window.open("https://twitter.com/intent/tweet?text="+encodeURIComponent(tweet(record)),"_blank");
   if(opened)opened.opener=null;else throw Error("El navegador bloqueó la ventana de X.");
  },publishing);
  add("PUB","Ya publicada: registrar una publicación y mover a Archivo",async()=>{
   if(!confirm("¿Confirmas que YA has publicado esta noticia? PUB la moverá a Archivo y sumará 1 al contador de las últimas 24 horas. No se enviará nada automáticamente a X."))return;
   await action(item,"publish");
   globalThis.dispatchEvent(new Event("ttv2:publication-recorded"));
   await onChange("archived",item);
  },publishing);
  add("Quitar","Mover a Archivo SIN publicar y SIN aumentar el contador",async()=>{
   if(!confirm("¿Quitar esta noticia de Elaboradas y pasarla a Archivo sin sumar publicaciones?"))return;
   await action(item,"archive");await onChange("archived",item);
  });
  const r=add("R · Rojo","Marcar o desmarcar en rojo; no archiva ni publica",async()=>{await action(item,"mark",!item.marked);await onChange();});
  r.setAttribute("aria-pressed",String(item.marked===true));
  add("RE","Investigar y elaborar de nuevo, con imagen nueva",async()=>{
   if(!confirm("¿Reelaborar esta noticia? Se conservan el texto y la imagen anteriores en el historial."))return;
   await action(item,"rework");await onChange();
  });
  add("RE-X","Solicitar una reelaboración con búsqueda en X y contrastación",async()=>{
   const hints=window.prompt("Pistas para intentar consultar X y contrastar con otras fuentes (mínimo 10 caracteres). Se solicitará la búsqueda en el nuevo chat, pero no se garantiza el acceso a publicaciones de X:");
   if(hints===null)return;if(hints.trim().length<10||hints.length>1200)throw Error("Introduce entre 10 y 1200 caracteres.");
   await action(item,"rework_x",undefined,hints.trim());await onChange();
  });
  if(item.image_available||item.image_suppressed){
   add(item.image_suppressed?"Restaurar IA":"Quitar IA","Cambiar la visibilidad en V2 y V1 conservando el original",async()=>{
    await action(item,"suppress_image",!item.image_suppressed);await onChange();
   },artwork);
   attachPublicImageToggle(item,artwork,onChange);
  }
  if(!item.image_available&&!item.image_suppressed){
   add("Copiar prompt IA","Copiar el encargo de imagen para esta noticia y revisión",()=>navigator.clipboard.writeText(prompt(item,record)),artwork);
   const link=el("a","publish-action","GPT IMA");link.href="https://chatgpt.com/images/";link.target="_blank";link.rel="noopener noreferrer";
   artwork.append(link);
   add("Pegar IA","Pegar o seleccionar el original PNG",()=>new Promise(resolve=>{
    const dialog=el("dialog","news-paste-dialog");dialog.append(el("p","","Pega aquí el original de ChatGPT Images o selecciónalo."));
    const input=el("input");input.type="file";input.accept="image/png";const status=el("p","","");
    const close=el("button","","Cerrar");close.type="button";close.onclick=()=>dialog.close();
    const upload=async file=>{
     if(!file)return;status.textContent="Asociando original…";
     try{
      const response=await fetch("/api/news-manual-image?id="+item.event_id+"&revision="+item.revision,
       {method:"POST",credentials:"same-origin",headers:{"content-type":file.type,"x-ttv2-action":"1"},body:file});
      if(!response.ok)throw Error("No se pudo asociar el original. Usa PNG/JPEG, mínimo 1024px y máximo 8 MB.");
      const receipt=await response.json();if(!receipt.association_verified)throw Error("Asociación sin confirmar.");
      dialog.close();await onChange();
     }catch(error){status.textContent=error.message;}
    };
    input.onchange=()=>void upload(input.files[0]);
    dialog.addEventListener("paste",event=>{const file=[...(event.clipboardData?.files||[])].find(x=>/^image\//.test(x.type));if(file){event.preventDefault();void upload(file);}});
    dialog.append(input,status,close);document.body.append(dialog);
    dialog.addEventListener("close",()=>{dialog.remove();resolve();},{once:true});dialog.showModal();
   }),artwork);
  }
  if(item.image_available){
   add("P-IA","Compartir con el original IA",async()=>{
    const response=await fetch(endpoint(item),{credentials:"same-origin"});if(!response.ok)throw Error("Original no disponible.");
    const blob=await response.blob(),ext={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}[blob.type];
    if(!ext)throw Error("Formato de imagen no válido.");const file=new File([blob],item.event_id+"-r"+item.revision+"."+ext,{type:blob.type});
    if(navigator.canShare?.({files:[file]})&&navigator.share)await navigator.share({text:tweet(record),files:[file]});
    else{
     const url=URL.createObjectURL(blob),a=el("a");a.href=url;a.download=file.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);
     await navigator.clipboard.writeText(tweet(record));notice("Original descargado y texto copiado. Adjunta la imagen al publicar en X.");
    }
   },publishing);
  }
  body.append(actions);
 }
 return {attach,attachIncident,attachPending,prompt};
})();
