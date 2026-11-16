/**
 * Integration adapter for Site V1 v97. Does not replace its history or routes.
 * Import into the existing public Site data loader; call loadV2News() for the
 * live Noticias list. Keep V1 storage for Hemeroteca, relations and old URLs.
 * New current news identities are the exact ttn2 ID plus editorial revision.
 */
export const NEWS_V2_ORIGIN="https://ttactualidad-v2-private-test.fabricelop.workers.dev";
export async function loadV2News({fetcher=fetch}={}){
 const response=await fetcher(NEWS_V2_ORIGIN+"/api/public-news",{headers:{Accept:"application/json"},cache:"no-store"});
 if(!response.ok)throw Error("NOTICIAS_V2_NO_DISPONIBLES");
 const feed=await response.json();
 if(feed?.schema_version!==1||feed.source!=="ttittulares-v2"||!Array.isArray(feed.items))
  throw Error("NOTICIAS_V2_CONTRATO_INVALIDO");
 const seen=new Set();
 return {observed_at:feed.observed_at,items:feed.items.map(row=>{
  if(!/^ttn2-[a-f0-9]{24}$/.test(row.event_id)||!Number.isSafeInteger(row.revision)||row.revision<1||
     !["ready","archived"].includes(row.group)||typeof row.tweet_text!=="string"||seen.has(row.event_id))
   throw Error("NOTICIAS_V2_IDENTIDAD_INVALIDA");
  seen.add(row.event_id);
  return {id:row.event_id,event_id:row.event_id,revision:row.revision,title:row.title,
   headline:row.title,explanation:row.tweet_text,factual_summary:row.factual_summary,
   prepared_at:row.prepared_at,source_evidence:row.source_evidence,
   image_url:row.image_url?new URL(row.image_url,NEWS_V2_ORIGIN).href:null,
   editorial_sha256:row.editorial_sha256,status:row.group==="archived"?"archived":"ready"};
 })};
}
