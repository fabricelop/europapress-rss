// Read-only corroboration of editorial identity when the historical image-job
// receipt was never published in GitHub. This is NOT proof of an exact job.
// Never create a match from a title, a similar image, or a guessed revision.
const ROOT='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/';
const ID=/^[a-f0-9]{12}$/i;
const PROJECTS=new Set(['ttittulares','ttendencias']);
const sameRevision=(actual,expected)=>actual!==null&&actual!==undefined&&String(actual).trim()!==''&&Number.isSafeInteger(Number(actual))&&Number(actual)===expected;
async function readJson(path,fetcher){
 try{
  const r=await fetcher(ROOT+path,{redirect:'error',signal:AbortSignal.timeout(9000)});
  if(!r.ok)return null;
  const data=await r.json();
  return data&&typeof data==='object'&&!Array.isArray(data)?data:null;
 }catch{return null}
}
export async function lookupEditorialIdentity(identity,fetcher=fetch){
 const {project,editorialId,revision}=identity||{};
 if(!PROJECTS.has(project)||!ID.test(String(editorialId||''))||!Number.isSafeInteger(revision)||revision<0)return null;
 if(project==='ttittulares'){
  const prepared=await readJson('ttittulares/prepared.json',fetcher);
  const item=Array.isArray(prepared?.items)?prepared.items.find(x=>x?.event_id===editorialId&&sameRevision(x.revision,revision)):null;
  if(item)return {project,editorialId,revision,title:String(item.title||'').slice(0,210),source:'ttittulares/prepared.json'};
  const status=await readJson('ttittulares/status.json',fetcher);
  const event=status?.events?.[editorialId];
  if(!event||!sameRevision(event.revision,revision))return null;
  return {project,editorialId,revision,title:String(event.title||'').slice(0,210),source:'ttittulares/status.json'};
 }
 const trends=await readJson('trends/site-top30-current.json',fetcher);
 const item=Array.isArray(trends?.items)?trends.items.find(x=>x?.editorial_id===editorialId&&sameRevision(x.revision,revision)):null;
 return item?{project,editorialId,revision,title:String(item.name||'').slice(0,210),source:'trends/site-top30-current.json'}:null;
}
