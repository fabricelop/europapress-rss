// TT Fotos cloud: pure validations and exact identity resolution.
// No ChatGPT private APIs, no iPhone inbox writes, no publication.
export const ID_RE = /^(tt|tr)-img-auto-([a-z0-9]{12})-r(\d+)-a\d+-\d{10,}$/i;
export const SHA_RE = /^[0-9a-f]{64}$/i;
export const PROJECTS = new Set(['ttittulares','ttendencias']);
export const MAX_PNG = 8 * 1024 * 1024;
const PNG_SIG = [137,80,78,71,13,10,26,10];
export function validPng(bytes){return bytes instanceof Uint8Array && bytes.length>=24 && bytes.length<=MAX_PNG && PNG_SIG.every((n,i)=>bytes[i]===n)}
export async function rasterSha(bytes){const d=await crypto.subtle.digest('SHA-256',bytes);return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,'0')).join('')}
export function commandDetails(commandId){
 const m=ID_RE.exec(String(commandId||''));if(!m)return null;
 return {commandId:m[0],project:m[1].toLowerCase()==='tt'?'ttittulares':'ttendencias',editorialId:m[2],revision:Number(m[3])};
}
export function validChatUrl(url){
 try{const u=new URL(String(url||''));return u.protocol==='https:'&&u.hostname==='chatgpt.com'&&/^\/c\/[0-9a-f-]{36}$/i.test(u.pathname)&&!u.username&&!u.password?u.origin+u.pathname:null}catch{return null}
}
export function exactJob(job,identity){
 return !!job && String(job.command_id||'')===identity.commandId &&
  String(job.target_id||job.trend_id||job.event_id||'')===identity.editorialId &&
  Number(job.revision??0)===identity.revision &&
  String(job.project||identity.project).toLowerCase()===identity.project;
}
const markerRe=/(TTITTULARES_IMAGE_JOB_V4|TTENDENCIAS_IMAGE_JOB_V4)\s+((?:tt|tr)-img-auto-[a-z0-9]{12}-r\d+-a\d+-\d{10,})/i;
export function sourceEvidence(evidence,identity,job){
 // A prompt and an original image must come from the SAME visible ChatGPT turn.
 // A filename, visual resemblance, title, date, or arbitrary text is insufficient.
 if(!evidence||evidence.kind!=='same_turn_image' || !['original_image','rendered_png_copy'].includes(evidence.rasterSource))return {automatic:false,reason:'SOURCE_NOT_PROVEN'};
 const url=validChatUrl(evidence.conversationUrl),marker=markerRe.exec(String(evidence.promptText||''));
 if(!url||!marker||marker[2]!==identity.commandId)return {automatic:false,reason:'EXACT_TURN_MARKER_MISSING'};
 if(identity.project==='ttittulares'&&marker[1]!=='TTITTULARES_IMAGE_JOB_V4')return {automatic:false,reason:'WRONG_PROJECT_MARKER'};
 if(identity.project==='ttendencias'&&marker[1]!=='TTENDENCIAS_IMAGE_JOB_V4')return {automatic:false,reason:'WRONG_PROJECT_MARKER'};
 const known=validChatUrl(job?.conversation_url||job?.chat_url||'');
 if(known && known!==url)return {automatic:false,reason:'CONVERSATION_MISMATCH'};
 return {automatic:true,reason:evidence.rasterSource==='original_image'?'EXACT_CHAT_TURN_AND_JOB':'EXACT_CHAT_TURN_RENDERED_COPY',conversationUrl:url};
}
export function safeLabel(s,max=160){return String(s||'').replace(/[\r\n\t\x00-\x1f]/g,' ').slice(0,max)}
export function assertMatch(candidate,job){
 const id=commandDetails(candidate?.commandId);
 if(!id||!exactJob(job,id)||candidate.project!==id.project||candidate.editorialId!==id.editorialId||Number(candidate.revision)!==id.revision)throw Error('JOB_IDENTITY_MISMATCH');
 return id;
}