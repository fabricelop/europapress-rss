'use strict';
const $=id=>document.getElementById(id);
const expected='https://chatgpt.com/';
const target=chrome.runtime.getManifest().host_permissions.find(x=>x.startsWith('https://')&&!x.startsWith(expected));
const origin=target?target.replace(/\/\*$/,''):null;
const explanation={NOT_FULL_RESOLUTION:'Imagen abierta con tamaño insuficiente',SOURCE_CORS_RESTRICTED:'Protección de origen del navegador',VISIBLE_IMAGE_FETCH_UNAVAILABLE:'La imagen no permite lectura directa',IMAGE_FORMAT_UNSUPPORTED:'Formato no compatible',PNG_INVALID_OR_TOO_LARGE:'Original demasiado grande o inválido',OPEN_CHATGPT_IMAGES_OR_CONVERSATION:'Abre ChatGPT Imágenes o una conversación',SITE_TAB_NOT_READY:'Monitor TT Fotos no disponible o sin iniciar sesión'};
function count(id,value){$(id).textContent=Number.isFinite(value)?String(value):'–'}
function stats(s){count('visible',s?.visibleCandidates);count('stored',s?.stored);count('unmatched',s?.unmatched);count('skipped',s?.skipped);if(s?.reasons){$('reasons').textContent=Object.entries(s.reasons).map(([key,n])=>(explanation[key]||key)+': '+n).join(' · ')}}
function status(s){$('status').textContent=s}
function sourceTab(t){try{const u=new URL(t?.url||'');return u.origin==='https://chatgpt.com'&&(u.pathname.startsWith('/images')||/^\/c\//.test(u.pathname))}catch{return false}}
$('images').onclick=()=>chrome.tabs.create({url:'https://chatgpt.com/images'});
$('monitor').onclick=()=>{if(origin)chrome.tabs.create({url:origin+'/fotos'});else status('El conector no tiene el dominio de TT Fotos configurado.')};
$('scan').onclick=async()=>{
 $('scan').disabled=true;stats({});$('reasons').textContent='';status('Comprobando imágenes visibles en la pestaña de ChatGPT…');
 try{
  const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
  if(!sourceTab(tab))throw Error('OPEN_CHATGPT_IMAGES_OR_CONVERSATION');
  const report=await chrome.tabs.sendMessage(tab.id,{type:'TT_FOTOS_SCAN'});
  if(!report?.ok)throw Error(report?.error||'RECOVERY_FAILED');
  stats(report);
  if(report.visibleCandidates===0){status(report.thumbnailsVisible?'Hay miniaturas, pero no imágenes a tamaño completo recuperables. Abre una imagen desde ChatGPT Imágenes y repite.':'No hay originales a tamaño completo visibles. Abre una imagen en ChatGPT Imágenes y vuelve a importar.');return}
  status('Guardadas: '+report.stored+' · Sin asociar: '+report.unmatched+' · Omitidas: '+report.skipped+'. Para otras imágenes, cambia la vista y repite.');
 }catch(e){status(explanation[e.message]||'No se pudo completar la recuperación: '+String(e.message||'Error').slice(0,100));}
 finally{$('scan').disabled=false}
};
chrome.runtime.onMessage.addListener(message=>{
 if(message?.type!=='TT_FOTOS_PROGRESS')return;
 stats(message);status('Procesando imágenes visibles: '+message.scanned+' de '+message.visibleCandidates+'…');
});