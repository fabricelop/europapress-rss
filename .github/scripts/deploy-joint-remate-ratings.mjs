// Single Vercel REST deployment of both web apps, without CLI user lookup.
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const token=process.env.VERCEL_TOKEN, teamId=process.env.VERCEL_ORG_ID, projectId=process.env.VERCEL_PROJECT_ID;
if(!token||!teamId||!projectId)throw new Error("Missing Vercel credentials");
const auth={Authorization:"Bearer "+token};
const projectResponse=await fetch("https://api.vercel.com/v9/projects/"+encodeURIComponent(projectId)+"?teamId="+encodeURIComponent(teamId),{headers:auth});
if(!projectResponse.ok)throw new Error("Project lookup HTTP "+projectResponse.status+": "+(await projectResponse.text()).slice(0,300));
const project=await projectResponse.json();
if(project.name!=="europapress-rss")throw new Error("Unexpected project: "+project.name);
const root=String(project.rootDirectory||"").replace(/\/$/,"");
if(root&&root!=="vercel-webhook")throw new Error("Unexpected rootDirectory: "+root);
const prefix=root?root+"/":"", base=path.resolve("vercel-webhook");
const skip=new Set(["node_modules",".vercel",".git","test",".deploy-trigger",".DS_Store"]);
async function collect(dir,rel=""){
 const all=[];
 for(const entry of await fs.readdir(dir,{withFileTypes:true})){
  if(skip.has(entry.name))continue;
  const local=path.join(dir,entry.name), relative=rel?rel+"/"+entry.name:entry.name;
  if(entry.isDirectory())all.push(...await collect(local,relative));
  else if(entry.isFile())all.push({local,file:prefix+relative});
 }
 return all;
}
const sources=await collect(base);
if(sources.length<12||
 !sources.some(x=>x.file.endsWith("ttittulares/index.html"))||
 !sources.some(x=>x.file.endsWith("ttendencias/explicadas/index.html"))||
 !sources.some(x=>x.file.endsWith("api/ttendencias-control.js"))||
 !sources.some(x=>x.file.endsWith("api/ttittulares-control.js")))
 throw new Error("Incomplete joint release file manifest");
const uploads=[];
for(const source of sources){
 const data=await fs.readFile(source.local),sha=crypto.createHash("sha1").update(data).digest("hex");
 const response=await fetch("https://api.vercel.com/v2/files?teamId="+encodeURIComponent(teamId),{
  method:"POST",headers:{...auth,"x-vercel-digest":sha,"content-type":"application/octet-stream"},body:data
 });
 if(!response.ok)throw new Error("Upload failed "+source.file+" HTTP "+response.status+": "+(await response.text()).slice(0,350)+". Deployment NOT created.");
 uploads.push({file:source.file,sha,size:data.byteLength});
}
console.log("All "+uploads.length+" files uploaded, SHA1 digests recorded. Project root="+(root||"(root)")+".");
const payload={
 name:project.name,project:projectId,target:"production",files:uploads,
 projectSettings:{framework:null},
 meta:{jointRelease:"remate-ratings-v1"}
};
const response=await fetch("https://api.vercel.com/v13/deployments?teamId="+encodeURIComponent(teamId)+"&skipAutoDetectionConfirmation=1",{
 method:"POST",headers:{...auth,"content-type":"application/json"},body:JSON.stringify(payload)
});
const created=await response.json().catch(()=>({}));
if(!response.ok)throw new Error("Create deployment HTTP "+response.status+": "+JSON.stringify(created.error||created).slice(0,650));
const id=created.id||created.uid;
if(!id)throw new Error("Deployment response missing id: "+JSON.stringify(created).slice(0,650));
console.log("ONE_DEPLOYMENT_CREATED id="+id+" url="+(created.url||"pending")+" state="+(created.readyState||created.state||"pending"));
for(let i=0;i<80;i++){
 await new Promise(resolve=>setTimeout(resolve,4000));
 const statusResponse=await fetch("https://api.vercel.com/v13/deployments/"+encodeURIComponent(id)+"?teamId="+encodeURIComponent(teamId),{headers:auth});
 if(!statusResponse.ok)throw new Error("Inspect deployment "+id+" HTTP "+statusResponse.status);
 const status=await statusResponse.json();
 const state=status.readyState||status.state||"UNKNOWN";
 if(i===0||i%5===0||["READY","ERROR","CANCELED","BLOCKED"].includes(state))console.log("Deployment "+id+": "+state);
 if(state==="READY"){console.log("JOINT_PRODUCTION_READY id="+id+" url=https://"+(status.url||created.url));process.exit(0)}
 if(["ERROR","CANCELED","BLOCKED"].includes(state))throw new Error("Deployment "+id+" failed state="+state+" "+JSON.stringify(status.error||status.aliasError||{}).slice(0,500));
}
throw new Error("Deployment "+id+" still pending; inspect Vercel before any retry.");
