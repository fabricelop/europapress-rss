export default async function handler(req,res){
  res.setHeader("cache-control","no-store, max-age=0");
  if(req.method!=="GET")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    const host=String(req.headers["x-forwarded-host"]||req.headers.host||"europapress-rss.vercel.app").split(",")[0].trim();
    const proto=String(req.headers["x-forwarded-proto"]||"https").split(",")[0].trim();
    const origin=host.includes("localhost")?`${proto}://${host}`:`https://${host}`;
    const r=await fetch(origin+"/api/ttittulares-control",{headers:{accept:"application/json"}});
    const body=await r.json();
    if(!r.ok||!body?.ok)throw new Error(body?.error||("Control TTiTTulares HTTP "+r.status));
    const s=body.status||{},prepared=body.prepared?.items||[];
    const counts={
      listas:Number(s.ready_count??prepared.length)||0,
      elaboracion:Number(s.processing_count||0),
      creciendo:Number(s.three_source_count||0),
      tendencias:Number(s.problematic_count||0)
    };
    return res.status(200).json({
      ok:true,
      updated_at:new Date().toISOString(),
      refresh_after_seconds:900,
      counts,
      links:{
        listas:"/ttittulares/?view=ready",
        elaboracion:"/ttittulares/?view=processing",
        creciendo:"/ttittulares/?view=growing",
        tendencias:"/ttittulares/?view=problematic"
      }
    });
  }catch(e){
    console.error("ttittulares-widget",e);
    return res.status(500).json({ok:false,error:String(e?.message||e)});
  }
}
