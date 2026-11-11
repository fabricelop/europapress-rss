import {commandDetails,exactJob} from './core.mjs';
import {lookupEditorialIdentity} from './editorial-registry.mjs';
// First choice: exact upstream image-job receipt. The legacy job-file location
// does not currently exist for all jobs. A 404 can fall back to a READ-ONLY
// editorial ID+revision check, but that weaker provenance is always labelled.
// A conflicting job receipt or an upstream error fails closed.
const REPO='https://raw.githubusercontent.com/fabricelop/europapress-rss/';
export function createGithubJobProvider(fetcher=fetch){
 return {async find(commandId){
   const identity=commandDetails(commandId);if(!identity)return null;
   const dir=identity.project==='ttittulares'?'control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/':'control/ttendencias-run-trigger/trends/image-runs/jobs/';
   let missing=false;
   try{
     const r=await fetcher(REPO+dir+identity.editorialId+'.json',{redirect:'error',signal:AbortSignal.timeout(9000)});
     if(r.status===404)missing=true;
     else if(!r.ok)return null;
     else{
       const job=await r.json();
       return exactJob(job,identity)?{...job,verification:'exact_job'}:null;
     }
   }catch{return null}
   if(!missing)return null;
   const editorial=await lookupEditorialIdentity(identity,fetcher);
   if(!editorial)return null;
   // The commandId comes from the ChatGPT source turn or an editor's input,
   // NOT from the editorial catalogue. This is NOT an exact job receipt.
   return {command_id:identity.commandId,target_id:identity.editorialId,
     project:identity.project,revision:identity.revision,
     target_name:editorial.title,verification:'editorial_identity_only',
     editorial_source:editorial.source};
 }};
}
