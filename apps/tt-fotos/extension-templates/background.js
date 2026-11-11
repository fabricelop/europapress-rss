/* Explicit action only: sender tab -> signed-in TT Fotos Site tab; never disk. */
'use strict';
const DEST='__TT_FOTOS_ORIGIN__';
async function siteTab(){
 const tabs=await chrome.tabs.query({url:DEST+'/*'});
 let tab=tabs.find(t=>{try{return new URL(t.url).pathname.startsWith('/fotos')}catch{return false}});
 if(!tab)tab=await chrome.tabs.create({url:DEST+'/fotos',active:false});
 return tab;
}
async function sendToSite(message){
 const tab=await siteTab();let err=null;
 for(let tries=0;tries<12;tries++){
   try{return await chrome.tabs.sendMessage(tab.id,{type:'TT_FOTOS_SITE_IMPORT',base64:message.base64,metadata:message.metadata})}
   catch(e){err=e;await new Promise(r=>setTimeout(r,750))}
 }
 return {ok:false,error:'SITE_TAB_NOT_READY: '+String(err?.message||'').slice(0,70)};
}
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
 if(message?.type!=='TT_FOTOS_FORWARD')return;
 if(!sender.tab?.url?.startsWith('https://chatgpt.com/')){reply({ok:false,error:'SOURCE_NOT_CHATGPT'});return}
 if(typeof message.base64!=='string'||message.base64.length>12e6){reply({ok:false,error:'IMAGE_PAYLOAD_INVALID'});return}
 sendToSite(message).then(reply,e=>reply({ok:false,error:'SITE_TRANSFER_FAILED'}));return true;
});
chrome.action.onClicked.addListener(async tab=>{
 let report;try{report=await chrome.tabs.sendMessage(tab.id,{type:'TT_FOTOS_SCAN'})}catch{report={ok:false,error:'OPEN_CHATGPT_IMAGES_OR_CONVERSATION'}}
 await chrome.action.setBadgeText({tabId:tab.id,text:report?.ok?String(report.stored||0):'!'});
 await chrome.action.setBadgeBackgroundColor({tabId:tab.id,color:report?.ok?'#177a65':'#9c4c4c'});
 // The browser action result is visible via the badge; detailed reasons
 // are not printed to console, protecting sensitive browsing metadata.
});