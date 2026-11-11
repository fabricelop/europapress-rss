/* Runs in the user's authenticated TTActualidad Site tab; no tokens or cookies read. */
(()=>{
 'use strict';
 chrome.runtime.onMessage.addListener((message,_sender,reply)=>{
   if(message?.type!=='TT_FOTOS_SITE_IMPORT')return;
   const id=crypto.randomUUID();
   let done=false;
   const timeout=setTimeout(()=>finish({ok:false,error:'SITE_BRIDGE_TIMEOUT'}),55000);
   function finish(out){if(done)return;done=true;clearTimeout(timeout);window.removeEventListener('message',onReply);reply(out)}
   function onReply(event){
     if(event.origin!==location.origin||event.source!==window)return;
     if(event.data?.type!=='TT_FOTOS_DIRECT_UPLOAD_RESULT'||event.data?.id!==id)return;
     finish({ok:Boolean(event.data.ok),needsReview:Boolean(event.data.needsReview),error:event.data.error});
   }
   window.addEventListener('message',onReply);
   window.postMessage({type:'TT_FOTOS_DIRECT_UPLOAD',id,base64:message.base64,metadata:message.metadata},location.origin);
   return true;
 });
})();