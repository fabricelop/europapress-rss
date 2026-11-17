"use strict";
window.TTNewsActions=(()=>{
 const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
 const notice=message=>{const n=document.getElementById("news-error");n.textContent=message;n.hidden=false;};
 const endpoint=item=>"/api/news-image?id="+item.event_id+"&revision="+item.revision;
 const weighted=text=>text.replace(/https?:\/\/\S+/gu,"X".repeat(23)).length;
 function tweet(record){const text=record.tweet_text.trim(),url="https://ttactualidad.rainyraven22.chatgpt.site/";return weighted(text+"\n"+url)<=280?text+"\n"+url:text;}
 async function action(item,type,value,hints){
  const response=await fetch("/api/news-actions",{method:"POST",credentials:"same-origin",
   headers:{"content-type":"application/json","x-ttv2-action":"1"},
   body:JSON.stringify({action_id:crypto.randomUUID().replaceAll("-",""),event_id:item.event_id,
    revision:item.revision,action:type,...(value!==undefined?{value}:{}),...(hints?{hints}:{})})});
  if(!response.ok)throw Error(response.status===409?"La noticia ha cambiado. Actualiza la lista.":"No se pudo guardar la acción.");
  return response.json();
 }
 function prompt(item,record){return 'TTN2_IMAGE_JOB_V1 '+JSON.stringify({event_id:item.event_id,revision:item.revision})+
  "\nGenera UNA imagen original con ImageGen de mínimo 1024px. Cómic editorial europeo con una escena narrativa, protagonistas, acción clara, profundidad, luz y textura. Sin texto, titulares, hashtags, logos, diagramas ni collage. Una metáfora visual del hecho contrastado. En sucesos graves, escena contextual seria y respetuosa sin humor contra víctimas. Chat nuevo e independiente; no abras el chat editorial.\n"+
  record.title+"\n"+record.factual_summary+"\n"+record.tweet_text;}
 function attach({item,card,head,body,record,onChange}){
  if(body.querySelector(".news-actions"))return;
  if(item.image_available){
   const image=el("img","news-original");image.src=endpoint(item);image.alt="Ilustración editorial de "+item.title;image.loading="lazy";body.prepend(image);
  }else if(item.image_in_progress){body.append(el("p","news-image-working","▧ Imagen IA en elaboración"));}
  if(item.group!=="ready")return;
  card.classList.toggle("marked-red",item.marked===true);
  const actions=el("div","publish-actions news-actions");
  const add=(label,title,handler)=>{
   const b=el("button","publish-action",label);b.type="button";b.title=title;
   b.addEventListener("click",async event=>{event.preventDefault();event.stopPropagation();if(b.disabled)return;b.disabled=true;
    try{await handler();}catch(error){if(error.name!=="AbortError")notice(error.message);}finally{b.disabled=false;}});
   actions.append(b);return b;
  };
  const r=add("R","Marcar o desmarcar en rojo",async()=>{await action(item,"mark",!item.marked);await onChange();});
  r.setAttribute("aria-pressed",String(item.marked===true));
  add("RE","Investigar y elaborar de nuevo, con imagen nueva",async()=>{
   if(!confirm("¿Reelaborar esta noticia? Se conservan el texto y la imagen anteriores en el historial."))return;
   await action(item,"rework");await onChange();
  });
  add("RE-X","Investigar de nuevo en X con tus pistas",async()=>{
   const hints=window.prompt("Pistas para investigar en X y contrastar (mínimo 10 caracteres):");
   if(hints===null)return;if(hints.trim().length<10||hints.length>1200)throw Error("Introduce entre 10 y 1200 caracteres.");
   await action(item,"rework_x",undefined,hints.trim());await onChange();
  });
  add("P-X","Preparar el texto en X",()=>{
   const opened=window.open("https://twitter.com/intent/tweet?text="+encodeURIComponent(tweet(record)),"_blank");
   if(opened)opened.opener=null;else throw Error("El navegador bloqueó la ventana de X.");
  });
  add("PU","Registrar una publicación realizada; no envía a X",async()=>{
   await action(item,"publication");
   globalThis.dispatchEvent(new Event("ttv2:publication-recorded"));
   notice("PU registrada. El contador de noticias se ha actualizado; no se ha enviado nada a X.");
  });
  add("PUB","Mover de Elaboradas a Archivo",async()=>{
   await action(item,"archive");await onChange();
  });
  if(item.image_available||item.image_suppressed){
   add(item.image_suppressed?"Restaurar IA":"Quitar IA","Cambiar la visibilidad en V2 y V1 conservando el original",async()=>{
    await action(item,"suppress_image",!item.image_suppressed);await onChange();
   });
   const label=el("label","image-public-toggle");const toggle=el("input");toggle.type="checkbox";toggle.checked=item.public_image_visible===true;
   toggle.disabled=item.image_suppressed===true;toggle.setAttribute("role","switch");toggle.setAttribute("aria-label","Mostrar imagen en V1");
   toggle.addEventListener("change",async()=>{toggle.disabled=true;try{await action(item,"public_image",toggle.checked);await onChange();}
    catch(error){toggle.checked=!toggle.checked;notice(error.message);}finally{toggle.disabled=false;}});
   label.append(toggle,el("span","image-public-label","Imagen en V1"));actions.append(label);
  }
  if(!item.image_available&&!item.image_suppressed){
   add("Copiar prompt IA","Copiar el encargo de imagen para esta noticia y revisión",()=>navigator.clipboard.writeText(prompt(item,record)));
   const link=el("a","publish-action","GPT IMA");link.href="https://chatgpt.com/images/";link.target="_blank";link.rel="noopener noreferrer";actions.append(link);
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
   }));
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
   });
  }
  body.append(actions);
 }
 return {attach,prompt};
})();
