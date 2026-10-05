export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  return res.status(410).json({
    ok:false,
    disabled:true,
    error:"Avisos TTiTTulares retirados"
  });
}
