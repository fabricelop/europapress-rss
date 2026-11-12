'use strict';

// SERVER-INTEGRATION MODULE, not a separate ledger or deployed Site service.
// Site must supply verified episode identities, discovery and existing ledger writes.
const MAX_VISIBLE=5, MIN_CONFIDENCE=0.9;
function identity(x) {
  return x && typeof x.id==='string' && x.id.trim() &&
    Number.isInteger(x.revision) && x.revision>=0 ? x.id+':r'+x.revision:null;
}
function pairKey(n,t) {
  return identity(n)&&identity(t) ? identity(n)+'<->'+identity(t):null;
}
function sameEpisode(a,b) {
  if(!identity(a)||identity(a)!==identity(b))return false;
  const x=String(a.episodeFingerprint||''), y=String(b.episodeFingerprint||'');
  return !x||!y||x===y;
}
function timestamp(row) {
  for(const key of ['listedAt','readyAt','preparedAt','prepared_at']){
    const value=row?.[key], date=typeof value==='string'?Date.parse(value):NaN;
    if(Number.isFinite(date))return date;
  }
  return Number.NEGATIVE_INFINITY; // Unknown date is never 'most recent'.
}
function stateFor(items,news,trend) {
  const rows=(items||[]).filter(x=>sameEpisode(x.news,news)&&sameEpisode(x.trend,trend));
  if(rows.some(x=>x.state==='blocked'))return 'blocked';
  if(rows.some(x=>x.state==='linked'))return 'linked';
  return rows.some(x=>x.state==='suggested')?'suggested':null;
}
function trusted(match,news,trends){
  if(!sameEpisode(match.news,news)||!(trends||[]).some(t=>sameEpisode(t,match.trend)))return false;
  const e=match.evidence||{};
  const sources=new Set((e.independentSources||[]).filter(s=>typeof s==='string'&&s.trim()));
  const facts=new Set((e.distinctiveFacts||[]).filter(s=>typeof s==='string'&&s.trim()));
  // Matching a label or surname is NOT enough to link two editorial episodes.
  return match.sameEvent===true&&Number(match.confidence)>=MIN_CONFIDENCE&&
    sources.size>=2&&facts.size>=2&&
    typeof e.eventDescription==='string'&&e.eventDescription.trim().length>=12;
}
function recentFiveForTrend(items,trend,candidates=[],limit=MAX_VISIBLE){
  const n=Math.max(0,Math.min(MAX_VISIBLE,Number(limit)||0)), byId=new Map();
  const rows=(items||[]).filter(x=>x.state==='linked'&&sameEpisode(x.trend,trend)&&
    stateFor(items,x.news,trend)!=='blocked').map(x=>x.news).concat(candidates);
  for(const news of rows){
    const key=identity(news);if(!key)continue;
    const old=byId.get(key);
    if(!old||timestamp(news)>timestamp(old)||
      (!old.episodeFingerprint&&news.episodeFingerprint))byId.set(key,news);
  }
  return [...byId.values()].sort((a,b)=>timestamp(b)-timestamp(a)||
    identity(a).localeCompare(identity(b))).slice(0,n);
}
function planIncomingReady({readyNews,trends,matches,snapshot,limit=MAX_VISIBLE}){
  if(!identity(readyNews)||readyNews.ready!==true||
    typeof readyNews.text!=='string'||!readyNews.text.trim())
    return {links:[],skipped:[{reason:'news_not_verified_ready'}]};
  const existing=snapshot?.items||[],links=[],skipped=[],seen=new Set();
  for(const match of matches||[]){
    const key=pairKey(match.news,match.trend);if(!key||seen.has(key))continue;
    seen.add(key);
    if(!trusted(match,readyNews,trends)){skipped.push({key,reason:'not_verified_same_event'});continue;}
    const state=stateFor(existing,readyNews,match.trend);
    if(state==='blocked'||state==='linked'){skipped.push({key,reason:state});continue;}
    // Only the display top five rotates. Unlink is an editorial veto, so auto
    // ranking MUST NOT unlink old associations or erase manual decisions.
    if(!recentFiveForTrend(existing,match.trend,[readyNews],limit).some(n=>sameEpisode(n,readyNews))){
      skipped.push({key,reason:'not_among_five_newest'});continue;
    }
    links.push({key,news:readyNews,trend:match.trend,confidence:Number(match.confidence),
      evidence:match.evidence,reason:match.evidence.eventDescription.trim()});
  }
  links.sort((a,b)=>a.key.localeCompare(b.key));
  return {links,skipped};
}
// Triggered by EACH authoritative READY/Listas transition and bounded catch-up.
// writeDecision MUST atomically validate both IDs/revisions, manual blocks and
// idempotent commandId in the EXISTING authenticated Site relation ledger.
async function onReadyInListas({news,trends,findTrustedMatches,readReadyEpisode,
  readSnapshot,writeDecision,commandIdFor,limit=MAX_VISIBLE}){
  for(const [key,fn] of Object.entries({findTrustedMatches,readReadyEpisode,
    readSnapshot,writeDecision,commandIdFor}))
    if(typeof fn!=='function')throw new TypeError('missing_Site_callback:'+key);
  const ready=await readReadyEpisode(news);
  if(!ready||ready.ready!==true||!sameEpisode(ready,news))
    return {state:'stale_news',linked:[],skipped:[],errors:[]};
  const matches=await findTrustedMatches(ready,trends);
  const original=planIncomingReady({readyNews:ready,trends,matches,
    snapshot:await readSnapshot(),limit});
  const linked=[],skipped=[...original.skipped],errors=[];
  for(const link of original.links){
    try {
      const still=await readReadyEpisode(ready);
      if(!still||still.ready!==true||!sameEpisode(still,ready)){
        skipped.push({key:link.key,reason:'news_changed_before_write'});continue;
      }
      const latest=planIncomingReady({readyNews:still,trends,matches:[{
        news:link.news,trend:link.trend,confidence:link.confidence,sameEvent:true,
        evidence:link.evidence}],snapshot:await readSnapshot(),limit});
      if(!latest.links.length){
        skipped.push({key:link.key,reason:latest.skipped[0]?.reason||'superseded'});continue;
      }
      const receipt=await writeDecision({action:'link',
        expectedNews:{id:link.news.id,revision:link.news.revision},
        expectedTrend:{id:link.trend.id,revision:link.trend.revision},
        commandId:await commandIdFor(link.key),origin:'automatic_verified',
        reason:link.reason,onlyIfUnblocked:true});
      if(receipt?.state!=='linked'||!receipt.relationId){
        errors.push({key:link.key,reason:'unconfirmed_write_receipt'});continue;
      }
      if(stateFor((await readSnapshot()).items,link.news,link.trend)==='linked')
        linked.push(link.key);
      else errors.push({key:link.key,reason:'missing_site_readback'});
    }catch(e){errors.push({key:link.key,reason:String(e?.code||e?.message||e).slice(0,120)});}
  }
  return {state:errors.length?'partial':'verified',linked,skipped,errors};
}
module.exports={MAX_VISIBLE,MIN_CONFIDENCE,identity,pairKey,sameEpisode,
  timestamp,stateFor,trusted,recentFiveForTrend,planIncomingReady,onReadyInListas};
