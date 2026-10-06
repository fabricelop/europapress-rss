import controlHandler from "../lib/ttendencias-control-handler.js";
import runHandler from "../lib/ttendencias-run-handler.js";
import statusHandler from "../lib/ttendencias-run-status-handler.js";

function selectedHandler(req){
  const direct=req?.query?.__handler;
  if(typeof direct==="string"&&direct)return direct;
  try{return new URL(req.url||"/","http://localhost").searchParams.get("__handler")||"control"}catch{return "control"}
}
export default async function handler(req,res){
  const selected=selectedHandler(req);
  if(selected==="run")return runHandler(req,res);
  if(selected==="status")return statusHandler(req,res);
  return controlHandler(req,res);
}
