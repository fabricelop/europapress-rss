// Backend isolated from Telegram: never accept unverified Telegram updates here.
const IMG=/^https:\/\/raw\.githubusercontent\.com\/fabricelop\/europapress-rss\/main\/(?:trends|ttittulares)\/generated-images\/[A-Za-z0-9._-]+\.jpe?g$/;
const answer=(v,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{"content-type":"application/json","cache-control":"no-store"}});
function constantTimeEqual(a,b){const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return false;let diff=0;for(let i=0;i<x.length;i++)diff|=x[i]^y[i];return diff===0;}
function authorize(req,env){const secret=String(env.INSTAGRAM_INTERNAL_SECRET||"");return secret.length>=32&&constantTimeEqual(req.headers.get("authorization")||"","Bearer "+secret);}
function inputCheck(b){
  const source=String(b?.source||""),id=String(b?.event_id||""),revision=Number(b?.revision??0);
  const mid=Number(b?.telegram_message_id||0),image=String(b?.image_url||""),caption=String(b?.caption||"").trim();
  if(!["ttittulares","ttendencias"].includes(source)||!/^[a-zA-Z0-9_-]{5,64}$/.test(id)||!Number.isSafeInteger(revision)||revision<0||!Number.isSafeInteger(mid)||mid<1||!IMG.test(image)||!caption||caption.length>2200)throw Error("INVALID_INPUT");
  return {key:source+":"+id,source,id,revision,mid,image,caption};
}
async function meta(env,endpoint,params={},verb="POST"){
  if(!env.INSTAGRAM_PAGE_ACCESS_TOKEN)throw Error("MISSING_TOKEN");
  const data=new URLSearchParams(params);
  const url="https://graph.facebook.com/v26.0/"+endpoint+(verb==="GET"?"?"+data:"");
  const result=await fetch(url,{method:verb,headers:{"content-type":"application/x-www-form-urlencoded","authorization":"Bearer "+env.INSTAGRAM_PAGE_ACCESS_TOKEN},...(verb==="POST"?{body:data}:{})});
  const json=await result.json().catch(()=>({}));
  if(!result.ok||json.error)throw Error("META_REQUEST_FAILED");
  return json;
}
async function state(db,key){return db.prepare("SELECT * FROM instagram_posts WHERE id=?").bind(key).first();}
async function change(db,key,old,now,fields={}){
  const keys=Object.keys(fields);
  const sql="UPDATE instagram_posts SET state=?,updated_at=CURRENT_TIMESTAMP"+keys.map(k=>","+k+"=?").join("")+" WHERE id=? AND state=?";
  const r=await db.prepare(sql).bind(now,...keys.map(k=>fields[k]),key,old).run();
  return r.meta?.changes===1;
}
async function publish(env,item){
  const db=env.IG_DB,ig=String(env.INSTAGRAM_USER_ID||"");
  if(!db||!/^\d{10,25}$/.test(ig)||!env.INSTAGRAM_PAGE_ACCESS_TOKEN)return answer({ok:false,error:"NOT_CONFIGURED"},503);
  await db.prepare("INSERT OR IGNORE INTO instagram_posts(id,source,event_id,revision,telegram_message_id,image_url,caption,state) VALUES(?,?,?,?,?,?,?,'reserved')")
    .bind(item.key,item.source,item.id,item.revision,item.mid,item.image,item.caption).run();
  let row=await state(db,item.key);
  if(!row)return answer({ok:false,error:"STORAGE_FAILURE"},503);
  if(row.image_url!==item.image||row.caption!==item.caption||Number(row.telegram_message_id)!==item.mid)return answer({ok:false,error:"SELECTION_CHANGED"},409);
  if(row.state==="published")return answer({ok:true,state:"published",duplicate:true,media_id:row.media_id,permalink:row.permalink});
  if(["publishing","uncertain","creating"].includes(row.state))return answer({ok:false,error:"NEEDS_RECONCILIATION",state:row.state},409);
  if(row.state==="failed_before_publish"){
    if(!await change(db,item.key,"failed_before_publish","reserved"))return answer({ok:false,error:"BUSY"},409);
    row=await state(db,item.key);
  }
  if(row.state==="reserved"){
    if(!await change(db,item.key,"reserved","creating"))return answer({ok:false,error:"BUSY"},409);
    try{
      const creation=await meta(env,ig+"/media",{image_url:item.image,caption:item.caption});
      if(!/^\d+$/.test(String(creation.id||"")))throw Error("BAD_CONTAINER");
      await change(db,item.key,"creating","container_created",{container_id:String(creation.id)});
      row=await state(db,item.key);
    }catch(_err){
      await change(db,item.key,"creating","failed_before_publish");
      return answer({ok:false,error:"CONTAINER_CREATION_FAILED"},502);
    }
  }
  if(row.state!=="container_created")return answer({ok:false,error:"NEEDS_RECONCILIATION"},409);
  let status;
  try{status=(await meta(env,row.container_id,{fields:"status_code"},"GET")).status_code;}
  catch(_err){return answer({ok:false,error:"STATUS_CHECK_FAILED"},502);}
  if(status==="IN_PROGRESS")return answer({ok:true,state:"processing",retry_after_seconds:15},202);
  if(status!=="FINISHED")return answer({ok:false,error:"CONTAINER_NOT_READY",status_code:status},422);
  if(!await change(db,item.key,"container_created","publishing"))return answer({ok:false,error:"BUSY"},409);
  try{
    const post=await meta(env,ig+"/media_publish",{creation_id:row.container_id});
    if(!/^\d+$/.test(String(post.id||"")))throw Error("NO_PUBLICATION_ID");
    if(!await change(db,item.key,"publishing","published",{media_id:String(post.id)}))throw Error("STORAGE_FAILURE");
    let permalink=null;
    try{
      permalink=(await meta(env,String(post.id),{fields:"permalink"},"GET")).permalink||null;
      if(permalink)await db.prepare("UPDATE instagram_posts SET permalink=? WHERE id=? AND state='published'").bind(permalink,item.key).run();
    }catch(_err){}
    return answer({ok:true,state:"published",media_id:String(post.id),permalink});
  }catch(_err){
    // A timeout may happen AFTER Meta published; NEVER silently retry.
    await change(db,item.key,"publishing","uncertain");
    return answer({ok:false,state:"uncertain",error:"CHECK_INSTAGRAM_MANUALLY"},503);
  }
}
export default {async fetch(req,env){
  const pathname=new URL(req.url).pathname;
  if(pathname==="/health"&&req.method==="GET")return answer({ok:true,service:"tt-actualidad-instagram",active:false});
  if(pathname!=="/publish"||req.method!=="POST")return answer({ok:false,error:"NOT_FOUND"},404);
  if(!authorize(req,env))return answer({ok:false,error:"UNAUTHORIZED"},401);
  let item;
  try{item=inputCheck(await req.json());}catch(_err){return answer({ok:false,error:"INVALID_REQUEST"},400);}
  try{return await publish(env,item);}catch(_err){return answer({ok:false,error:"INTERNAL_ERROR"},503);}
}};
export {authorize,inputCheck};
