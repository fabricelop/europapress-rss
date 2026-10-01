import handler from "./ttendencias-control.js";

export default async function top10Push(req,res){
  req.query = { ...(req.query || {}), view: "push-scan" };
  return handler(req,res);
}
