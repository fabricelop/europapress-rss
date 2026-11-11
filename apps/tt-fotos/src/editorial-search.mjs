// Editorial title/name search. Read-only data from the public TT news/trends repo.
import {commandDetails,exactJob} from '../../../site-patches/ttactualidad-fotos-review/cloud-v1/core.mjs';
const ROOT='https://raw.githubusercontent.com/fabricelop/europapress-rss/';
const SOURCES=[
 'main/ttittulares/prepared.json',
 'main/trends/site-top30-current.json'
];
const norm=s=>String(s||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLocaleLowerCase('es-ES');
const identifier=s=>/^[a-f0-9]{12}$/i.test(String(s||''));
async function json(url,fetcher){
 try{const res=await fetcher(url,{signal:AbortSignal.timeout(6000),redirect:'error'});return res.ok?await res.json():null}catch{return null}
}
export async function searchEditorial(query,fetcher=fetch){
 const q=norm(query).trim().slice(0,80);if(q.length<2)return [];
 const [news,trends]=await Promise.all(SOURCES.map(src=>json(ROOT+src,fetcher)));
 const all=[];
 for(const item of (Array.isArray(news?.items)?news.items:[])){
   if(!identifier(item.event_id)||!Number.isInteger(Number(item.revision)))continue;
   all.push({project:'ttittulares',editorialId:item.event_id,revision:Number(item.revision),title:String(item.title||'').slice(0,210)});
 }
 for(const item of (Array.isArray(trends?.items)?trends.items:[])){
   if(!identifier(item.editorial_id)||!Number.isInteger(Number(item.revision)))continue;
   all.push({project:'ttendencias',editorialId:item.editorial_id,revision:Number(item.revision),title:String(item.name||'').slice(0,210)});
 }
 return all.filter(x=>norm(x.title+' '+x.editorialId).includes(q)).slice(0,40);
}
export async function resolveEditorialCommand({project,editorialId,revision},fetcher=fetch){
 if(!identifier(editorialId)||!['ttittulares','ttendencias'].includes(project)||!Number.isSafeInteger(Number(revision))||Number(revision)<0)return null;
 const dir=project==='ttittulares'?'control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/':'control/ttendencias-run-trigger/trends/image-runs/jobs/';
 const job=await json(ROOT+dir+editorialId+'.json',fetcher);
 if(!job||Number(job.revision)!==Number(revision))return null;
 const identity=commandDetails(job.command_id);
 if(!identity||!exactJob(job,identity)||identity.project!==project||identity.editorialId!==editorialId||identity.revision!==Number(revision))return null;
 return {commandId:identity.commandId,project,editorialId,revision:identity.revision,title:String(job.target_name||'').slice(0,210)};
}