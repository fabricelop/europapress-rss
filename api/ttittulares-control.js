export default async function handler(req,res){
 if(req.method!=="POST")return res.status(405).json({error:"method"});
 const {action,event_id,instructions=""}=req.body||{};
 if(!["published","dismissed","rewrite"].includes(action)||!event_id)return res.status(400).json({error:"bad_request"});
 const token=process.env.GITHUB_TOKEN, base="https://api.github.com/repos/fabricelop/europapress-rss/contents/";
 if(!token)return res.status(503).json({error:"github_token_missing"});
 const h={Authorization:"Bearer "+token,Accept:"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28","Content-Type":"application/json"};
 const get=async p=>{const r=await fetch(base+p+"?ref=main",{headers:h});if(!r.ok)throw Error(await r.text());const j=await r.json();return {sha:j.sha,obj:JSON.parse(Buffer.from(j.content,"base64").toString("utf8"))}};
 const put=async(p,sha,obj,msg)=>{const r=await fetch(base+p,{method:"PUT",headers:h,body:JSON.stringify({message:msg,content:Buffer.from(JSON.stringify(obj,null,2)+"\n").toString("base64"),sha,branch:"main"})});if(!r.ok)throw Error(await r.text())};
 try{
  const [pr,de,qu]=await Promise.all([get("ttittulares/prepared.json"),get("ttittulares/decisions.json"),get("telegram/editorial-processing.json")]);
  const now=new Date().toISOString(), item=(pr.obj.items||[]).find(x=>x.event_id===event_id);
  pr.obj.items=(pr.obj.items||[]).filter(x=>x.event_id!==event_id);pr.obj.updated_at=now;
  de.obj.items=de.obj.items||[];de.obj.items.push({event_id,status:action==="rewrite"?"rewrite_requested":action,instructions:action==="rewrite"?instructions:undefined,decided_at:now,title:item?.title||""});de.obj.updated_at=now;
  if(action==="rewrite"){
   const q=(qu.obj.items||[]).find(x=>x.event_id===event_id);
   if(q){q.status="PROCESSING";q.selection_mode="REWRITE";q.rewrite_request=instructions;q.rewrite_requested_at=now;q.rewrite_version=(q.rewrite_version||1)+1}
   else (qu.obj.items=qu.obj.items||[]).push({event_id,title:item?.title||"",url:item?.url||"",status:"PROCESSING",selection_mode:"REWRITE",rewrite_request:instructions,rewrite_requested_at:now,rewrite_version:2,selected_at:now});
   qu.obj.updated_at=now;
  }
  await put("ttittulares/prepared.json",pr.sha,pr.obj,"TTiTTulares: "+action+" "+event_id);
  const de2=await get("ttittulares/decisions.json");de2.obj.items=de2.obj.items||[];de2.obj.items.push({event_id,status:action==="rewrite"?"rewrite_requested":action,instructions:action==="rewrite"?instructions:undefined,decided_at:now,title:item?.title||""});de2.obj.updated_at=now;await put("ttittulares/decisions.json",de2.sha,de2.obj,"Registrar decisión TTiTTulares");
  if(action==="rewrite"){const q2=await get("telegram/editorial-processing.json"),q=(q2.obj.items||[]).find(x=>x.event_id===event_id);if(q){q.status="PROCESSING";q.selection_mode="REWRITE";q.rewrite_request=instructions;q.rewrite_requested_at=now;q.rewrite_version=(q.rewrite_version||1)+1}else (q2.obj.items=q2.obj.items||[]).push({event_id,title:item?.title||"",url:item?.url||"",status:"PROCESSING",selection_mode:"REWRITE",rewrite_request:instructions,rewrite_requested_at:now,rewrite_version:2,selected_at:now});q2.obj.updated_at=now;await put("telegram/editorial-processing.json",q2.sha,q2.obj,"Reencolar TTiTTulares para rehacer")}
  return res.status(200).json({ok:true});
 }catch(e){return res.status(500).json({error:String(e.message||e)})}
}