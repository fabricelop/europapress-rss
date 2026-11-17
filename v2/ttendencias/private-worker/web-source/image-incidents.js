"use strict";
// Shared by Tendencias and Noticias. The button reads a recorded problem only.
globalThis.TTImageIncidents={
 attach({card,head,project,id,revision,available,manualRetry=false,retryPending=false,onChange}){
  if(available!==true)return;
  const make=(tag,cls,text)=>{const node=document.createElement(tag);node.className=cls;if(text!==undefined)node.textContent=text;return node;};
  const button=make("button","image-incident-button","I");button.type="button";
  button.title="Ver incidencia de imagen";button.setAttribute("aria-label","Incidencia de imagen");
  button.setAttribute("aria-expanded","false");
  const panel=make("section","image-incident-detail");panel.hidden=true;
  panel.id="image-incident-"+id+"-r"+revision;panel.setAttribute("role","status");
  panel.setAttribute("aria-label","Problema registrado al generar la imagen");
  button.setAttribute("aria-controls",panel.id);
  let loaded=false;
  button.addEventListener("click",async event=>{
   event.preventDefault();event.stopPropagation();
   const show=panel.hidden;card.open=true;panel.hidden=!show;
   button.setAttribute("aria-expanded",String(show));
   if(!show||loaded)return;
   button.disabled=true;panel.textContent="Consultando la incidencia registrada…";
   try{
    const params=new URLSearchParams({project,id,revision:String(revision)});
    const response=await fetch("/api/image-incidents?"+params,{credentials:"same-origin",cache:"no-store",signal:AbortSignal.timeout(15000)});
    if(!response.ok)throw Error("unavailable");
    const data=await response.json();
    if(data.project!==project||data.target_id!==id||data.revision!==revision||typeof data.available!=="boolean")throw Error("identity_mismatch");
    panel.replaceChildren();
    if(data.available){
     const problem=data.incident;
     if(!problem||typeof problem.code!=="string"||!/^[A-Z][A-Z0-9_]{2,119}$/.test(problem.code))throw Error("problem_invalid");
     panel.append(make("strong","","Incidencia de imagen"),make("p","image-incident-code",problem.code));
     if(typeof problem.detail==="string"&&problem.detail.trim())panel.append(make("p","",problem.detail));
     const at=new Date(problem.at);
     if(Number.isFinite(at.getTime()))panel.append(make("p","image-incident-time","Registrada · "+new Intl.DateTimeFormat("es-ES",{timeZone:"Europe/Madrid",dateStyle:"short",timeStyle:"short"}).format(at)));
     if(project==="ttittulares-v2"){
      if(retryPending)panel.append(make("p","image-retry-status","↻ Reintento solicitado. Se abrirá un chat nuevo cuando haya capacidad."));
      else if(manualRetry&&problem.retry_mode!=="none"&&!/(AUTH|LOGIN|CREDENTIAL|DISK|CLEANUP|CAPTCHA|LEASE_EXPIRED)/.test(problem.code)){
       const retry=make("button","image-retry-button","↻ Reintentar imagen");retry.type="button";
       retry.title="Generar desde cero en un chat nuevo, independientemente de los intentos anteriores";
       const status=make("p","image-retry-status","");
       retry.addEventListener("click",async click=>{
        click.preventDefault();click.stopPropagation();if(retry.disabled)return;
        retry.disabled=true;status.textContent="Registrando reintento manual…";
        try{
         const response=await fetch("/api/news-actions",{method:"POST",credentials:"same-origin",
          headers:{"content-type":"application/json","x-ttv2-action":"1"},
          body:JSON.stringify({action_id:crypto.randomUUID().replaceAll("-",""),event_id:id,revision,action:"retry_image"})});
         if(!response.ok){
          const result=await response.json().catch(()=>({}));
          if(result.error==="image_retry_already_requested")throw Error("El reintento ya está solicitado.");
          if(response.status===409)throw Error("La incidencia ha cambiado o el reintento no es seguro. Actualiza la ficha.");
          throw Error("No se pudo registrar el reintento.");
         }
         status.textContent="Reintento solicitado. La próxima imagen se generará en un chat nuevo.";
         retry.textContent="✓ Reintento solicitado";
         if(typeof onChange==="function")await onChange();
        }catch(error){status.textContent=error.message;retry.disabled=false;}
       });
       panel.append(retry,status);
      }
     }
    }else panel.append(make("p","","Esta revisión no tiene ninguna incidencia de imagen registrada."));
    loaded=true;
   }catch{
    panel.textContent="No se pudo consultar la incidencia registrada. Cierra este detalle y vuelve a pulsar I para reintentar.";
   }finally{button.disabled=false;}
  });
  head.append(button);card.append(panel);
 }
};
