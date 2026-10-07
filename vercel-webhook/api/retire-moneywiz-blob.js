import { del, list } from "@vercel/blob";

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  res.setHeader("content-type","application/json; charset=utf-8");

  if(req.method!=="GET"){
    res.status(405).end(JSON.stringify({ok:false,error:"method_not_allowed"}));
    return;
  }
  if(process.env.MONEY_CONTROL_RETIRE!=="1"){
    res.status(404).end(JSON.stringify({ok:false,error:"not_found"}));
    return;
  }

  const token=String(process.env.BLOB_READ_WRITE_TOKEN||"");
  if(!token){
    res.status(503).end(JSON.stringify({ok:false,error:"blob_token_missing"}));
    return;
  }

  try{
    const before=await list({access:"private",token,limit:1000});
    const paths=(before.blobs||[]).map(b=>b.pathname).filter(Boolean);
    if(paths.length)await del(paths,{token});
    const after=await list({access:"private",token,limit:1000});
    res.status(200).end(JSON.stringify({
      ok:true,
      deleted:paths.length,
      remaining:(after.blobs||[]).length,
      hadMore:!!before.hasMore
    }));
  }catch(error){
    console.error("retire-moneywiz-blob",error);
    res.status(500).end(JSON.stringify({ok:false,error:"retire_failed"}));
  }
}
