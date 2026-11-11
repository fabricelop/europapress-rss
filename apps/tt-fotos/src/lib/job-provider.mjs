import { commandDetails, exactJob } from './core.mjs';
// Retrieve an exact immutable command only from the upstream editorial job file.
// Indices may contain only the latest job. Missing/rotated records are NOT auto-matches.
const REPO='https://raw.githubusercontent.com/fabricelop/europapress-rss/';
export function createGithubJobProvider(fetcher=fetch){
 return {async find(commandId){
   const identity=commandDetails(commandId);if(!identity)return null;
   const dir=identity.project==='ttittulares'?'control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/':'control/ttendencias-run-trigger/trends/image-runs/jobs/';
   try{
     const r=await fetcher(REPO+dir+identity.editorialId+'.json',{redirect:'error',signal:AbortSignal.timeout(9000)});
     if(!r.ok)return null;
     const job=await r.json();
     return exactJob(job,identity)?job:null;
   }catch{return null}
 }};
}