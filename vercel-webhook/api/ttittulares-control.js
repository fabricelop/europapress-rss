import controlHandler from "../lib/ttittulares-control-handler.js";
import pushHandler from "../lib/ttittulares-push-handler.js";
import runHandler from "../lib/ttittulares-run-handler.js";
import statusHandler from "../lib/ttittulares-run-status-handler.js";

function selectedHandler(req){
  const direct=req?.query?.__handler;
  if(typeof direct==="string"&&direct)return direct;
  try{return new URL(req.url||"/","http://localhost").searchParams.get("__handler")||"control"}catch{return "control"}
}
export default async function handler(req,res){
  const selected=selectedHandler(req);
  if(selected==="push")return pushHandler(req,res);
  if(selected==="run")return runHandler(req,res);
  if(selected==="status")return statusHandler(req,res);
  return controlHandler(req,res);
}
