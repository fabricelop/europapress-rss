import crypto from 'node:crypto';
export const explanationHash=text=>crypto.createHash('sha256').update(String(text||'').trim()).digest('hex');
export function webReceiptContext(job,row,requestedHash){
  if(!row||!['explained','published'].includes(String(row.status||'').toLowerCase())||row.listas_group_role==='covered')return 'not_visible_explanation';
  if(['CANCELLED','SUPERSEDED'].includes(String(job.status||'').toUpperCase()))return 'cancelled_image_job';
  const snapshot=job.context_snapshot||{},id=String(job.target_id||job.trend_id||'');
  if(String(row.id)!==id||Number(row.revision||0)!==Number(job.revision||0))return 'revision_changed';
  if(!String(snapshot.explanation||'').trim()||String(snapshot.explanation).trim()!==String(row.explanation||'').trim())return 'explanation_changed';
  if(!snapshot.explained_at||Date.parse(snapshot.explained_at)!==Date.parse(row.explained_at))return 'editorial_episode_changed';
  if(requestedHash!==explanationHash(snapshot.explanation))return 'explanation_hash_mismatch';
  return null;
}
export function receiptGuard(job){return {version:4,trend_id:String(job.target_id||job.trend_id),revision:Number(job.revision||0),scope:'current_item_only',command_id:job.command_id,explanation:String(job.context_snapshot.explanation).trim(),explanation_sha256:explanationHash(job.context_snapshot.explanation),explained_at:job.context_snapshot.explained_at};}
