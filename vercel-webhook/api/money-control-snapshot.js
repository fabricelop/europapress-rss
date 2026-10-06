import snapshotHandler from "../lib/money-control-snapshot-handler.js";
import stateHandler from "../lib/money-control-state-handler.js";

function selectedHandler(req){
  const direct=req?.query?.__handler;
  if(typeof direct==="string"&&direct)return direct;
  try{return new URL(req.url||"/","http://localhost").searchParams.get("__handler")||"snapshot"}catch{return "snapshot"}
}
export default async function handler(req,res){
  return selectedHandler(req)==="state"?stateHandler(req,res):snapshotHandler(req,res);
}
