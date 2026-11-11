/* Runs only in the user's own ChatGPT UI. Uses user-visible DOM, no private API calls. */
(()=>{
 'use strict';
 const COMMAND=/(?:tt|tr)-img-auto-[a-z0-9]{12}-r\d+-a\d+-\d{10,}/i;
 const PREFIX=/(TTITTULARES_IMAGE_JOB_V4|TTENDENCIAS_IMAGE_JOB_V4)\s+((?:tt|tr)-img-auto-[a-z0-9]{12}-r\d+-a\d+-\d{10,})/i;
 const PNG=[137,80,78,71,13,10,26,10];
 function evidence(img){
   const chat=/^\/c\/[0-9a-f-]{36}$/i.test(location.pathname);
   let conversationUrl=chat?location.origin+location.pathname:null;
   if(!conversationUrl){const a=img.closest('a[href*="/c/"]');if(a){try{const u=new URL(a.href);if(u.hostname==='chatgpt.com'&&/^\/c\/[0-9a-f-]{36}$/i.test(u.pathname))conversationUrl=u.origin+u.pathname}catch{}}}
   let promptText='',kind='gallery_visible';
   if(chat){
     const turns=[...document.querySelectorAll('[data-message-author-role]')];
     const i=turns.findIndex(turn=>turn.contains(img));
     if(i>=0 && turns[i].getAttribute('data-message-author-role')==='assistant'){
       let previous=null;
       for(let k=i-1;k>=0;k--){if(turns[k].getAttribute('data-message-author-role')==='user'){previous=turns[k];break}}
       if(previous){const txt=String(previous.innerText||'');if(PREFIX.test(txt)){
          promptText=txt.slice(0,5000);kind='same_turn_image';
       }}
     }
   }
   return {kind,rasterSource:'original_image',conversationUrl,promptText,commandId:promptText.match(COMMAND)?.[0]||'',title:document.title||''};
 }
 function isVisible(el){const r=el.getBoundingClientRect();return r.width>=180&&r.height>=150&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight}
 async function bytesFor(img){
   if(!img.complete||img.naturalWidth<1024||img.naturalHeight<576||!isVisible(img))throw Error('NOT_FULL_RESOLUTION');
   const src=img.currentSrc||img.src;
   if(!src)throw Error('IMAGE_NOT_LOADED');
   // Only fetch what is already rendered in the user's own UI. No hidden API calls.
   // Many UI resources are WebP. In that case create a FULL-RES visual PNG
   // in browser memory, explicitly labelled a derived copy, not the original.
   let u=null,rasterSource='original_image';
   try{
     const res=await fetch(src,{credentials:'include',redirect:'error',signal:AbortSignal.timeout(15000)});
     if(!res.ok)throw Error('VISIBLE_IMAGE_FETCH_UNAVAILABLE');
     const type=res.headers.get('content-type')||'';
     if(/^image\/png(?:;|$)/i.test(type))u=new Uint8Array(await res.arrayBuffer());
     else if(/^image\/(webp|jpeg|jpg|avif)(?:;|$)/i.test(type)){
       const blob=await res.blob(),bitmap=await createImageBitmap(blob);
       if(bitmap.width<img.naturalWidth||bitmap.height<img.naturalHeight)throw Error('SOURCE_DOWNSAMPLED');
       const canvas=document.createElement('canvas');canvas.width=bitmap.width;canvas.height=bitmap.height;
       canvas.getContext('2d',{alpha:false}).drawImage(bitmap,0,0);bitmap.close();
       const png=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
       if(!png)throw Error('PNG_CONVERSION_FAILED');u=new Uint8Array(await png.arrayBuffer());rasterSource='rendered_png_copy';
     }else throw Error('IMAGE_FORMAT_UNSUPPORTED');
   }catch(err){
     // Canvas on a cross-origin image may be tainted: skip instead of
     // bypassing browser origin restrictions or calling private endpoints.
     if(err?.name==='SecurityError')throw Error('SOURCE_CORS_RESTRICTED');
     throw err;
   }
   if(!u||u.byteLength<24||u.byteLength>8*1024*1024||!PNG.every((v,i)=>u[i]===v))throw Error('PNG_INVALID_OR_TOO_LARGE');
   let bin='';for(let i=0;i<u.length;i+=16384)bin+=String.fromCharCode(...u.subarray(i,i+16384));
   return {base64:btoa(bin),rasterSource};
 }
 chrome.runtime.onMessage.addListener((message,_sender,reply)=>{
   if(message?.type!=='TT_FOTOS_SCAN')return;
   (async()=>{
     if(location.hostname!=='chatgpt.com'||(!location.pathname.startsWith('/images')&&!location.pathname.startsWith('/c/')))throw Error('OPEN_CHATGPT_IMAGES_OR_CONVERSATION');
     const thumbnailsVisible=[...document.images].filter(img=>img.complete&&isVisible(img)&&img.naturalWidth>=160).length;
     const images=[...document.images].filter(img=>img.naturalWidth>=1024&&img.naturalHeight>=576&&isVisible(img)).slice(0,12);
     let stored=0,unmatched=0,skipped=0;const reasons={};
     for(const img of images){
       try{
         const raster=await bytesFor(img),base64=raster.base64,metadata={...evidence(img),rasterSource:raster.rasterSource};
         const result=await chrome.runtime.sendMessage({type:'TT_FOTOS_FORWARD',base64,metadata});
         if(!result?.ok)throw Error(result?.error||'UPLOAD_FAILED');
         stored++;if(result.needsReview)unmatched++;
       }catch(e){skipped++;const reason=String(e.message||'ERROR').slice(0,60);reasons[reason]=(reasons[reason]||0)+1}
       chrome.runtime.sendMessage({type:'TT_FOTOS_PROGRESS',scanned:stored+skipped,visibleCandidates:images.length,stored,unmatched,skipped}).catch(()=>{});
     }
     return {ok:true,visibleCandidates:images.length,thumbnailsVisible,stored,unmatched,skipped,reasons,
       note:'Visible full-resolution resources only. WebP/JPEG may become marked rendered PNG copies; inaccessible sources are skipped.'};
   })().then(reply,e=>reply({ok:false,error:String(e.message||e).slice(0,100)}));
   return true;
 });
})();