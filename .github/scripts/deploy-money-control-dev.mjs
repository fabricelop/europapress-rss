import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const token=process.env.VERCEL_TOKEN;
const teamId=process.env.VERCEL_ORG_ID;
const projectId=process.env.VERCEL_PROJECT_ID;
if(!token||!teamId||!projectId)throw new Error("Missing Vercel credentials");

const auth={Authorization:"Bearer "+token};
const projectResponse=await fetch("https://api.vercel.com/v9/projects/"+encodeURIComponent(projectId)+"?teamId="+encodeURIComponent(teamId),{headers:auth});
if(!projectResponse.ok)throw new Error("Project lookup HTTP "+projectResponse.status+": "+(await projectResponse.text()).slice(0,300));
const project=await projectResponse.json();
if(project.name!=="europapress-rss")throw new Error("Unexpected project: "+project.name);
const root=String(project.rootDirectory||"").replace(/\/$/,"");
if(root&&root!=="vercel-webhook")throw new Error("Unexpected rootDirectory: "+root);
const prefix=root?root+"/":"";

const sources=[
  {local:"vercel-webhook/money-control/index.html",file:prefix+"money-control/index.html"},
  {local:"vercel-webhook/api/money-control-interpret.js",file:prefix+"api/money-control-interpret.js"},
  {local:"vercel-webhook/api/money-control-moneywiz-upload.js",file:prefix+"api/money-control-moneywiz-upload.js"}
];

const sourcePackage=JSON.parse(await fs.readFile(path.resolve("vercel-webhook/package.json"),"utf8"));
const aiVersion=String(sourcePackage?.dependencies?.ai||"").replace(/^[~^]/,"");
const blobVersion=String(sourcePackage?.dependencies?.["@vercel/blob"]||"").replace(/^[~^]/,"");
if(!aiVersion)throw new Error("Missing ai dependency in vercel-webhook/package.json");
if(!blobVersion)throw new Error("Missing @vercel/blob dependency in vercel-webhook/package.json");
const minimalPackage=Buffer.from(JSON.stringify({
  private:true,
  type:"module",
  dependencies:{ai:aiVersion,"@vercel/blob":blobVersion}
},null,2)+"\n");

const minimalConfig={
  "$schema":"https://openapi.vercel.sh/vercel.json",
  functions:{
    "api/money-control-interpret.js":{maxDuration:60},
    "api/money-control-moneywiz-upload.js":{maxDuration:30}
  },
  git:{deploymentEnabled:false},
  rewrites:[
    {source:"/api/money-control-snapshot",destination:"https://europapress-rss.vercel.app/api/money-control-snapshot"},
    {source:"/api/money-control-state",destination:"https://europapress-rss.vercel.app/api/money-control-state"},
    {source:"/money-control",destination:"/money-control/index.html"},
    {source:"/money-control/",destination:"/money-control/index.html"}
  ],
  headers:[
    {
      source:"/money-control/(.*)",
      headers:[
        {key:"Cache-Control",value:"no-cache, no-store, must-revalidate"},
        {key:"X-Content-Type-Options",value:"nosniff"},
        {key:"X-Frame-Options",value:"DENY"},
        {key:"Referrer-Policy",value:"no-referrer"},
        {key:"Permissions-Policy",value:"camera=(), microphone=(), geolocation=()"},
        {key:"Content-Security-Policy",value:"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}
      ]
    },
    {
      source:"/money-control",
      headers:[
        {key:"Cache-Control",value:"no-cache, no-store, must-revalidate"},
        {key:"X-Content-Type-Options",value:"nosniff"},
        {key:"X-Frame-Options",value:"DENY"},
        {key:"Referrer-Policy",value:"no-referrer"},
        {key:"Permissions-Policy",value:"camera=(), microphone=(), geolocation=()"},
        {key:"Content-Security-Policy",value:"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}
      ]
    }
  ]
};
const generated=Buffer.from(JSON.stringify(minimalConfig,null,2)+"\n");
const uploads=[];

async function uploadBuffer(file,data){
  const sha=crypto.createHash("sha1").update(data).digest("hex");
  const response=await fetch("https://api.vercel.com/v2/files?teamId="+encodeURIComponent(teamId),{
    method:"POST",
    headers:{...auth,"x-vercel-digest":sha,"content-type":"application/octet-stream"},
    body:data
  });
  if(!response.ok)throw new Error("Upload failed "+file+" HTTP "+response.status+": "+(await response.text()).slice(0,350));
  uploads.push({file,sha,size:data.byteLength});
}

for(const source of sources){
  const data=await fs.readFile(path.resolve(source.local));
  await uploadBuffer(source.file,data);
}
await uploadBuffer(prefix+"package.json",minimalPackage);
await uploadBuffer(prefix+"vercel.json",generated);

console.log("MONEY_CONTROL_DEV_FILES_UPLOADED="+uploads.length);
const payload={
  name:project.name,
  project:projectId,
  files:uploads,
  projectSettings:{framework:null},
  meta:{moneyControlDev:"semantic-ingest-v4"}
};
const response=await fetch("https://api.vercel.com/v13/deployments?teamId="+encodeURIComponent(teamId)+"&skipAutoDetectionConfirmation=1",{
  method:"POST",
  headers:{...auth,"content-type":"application/json"},
  body:JSON.stringify(payload)
});
const created=await response.json().catch(()=>({}));
if(!response.ok)throw new Error("Create deployment HTTP "+response.status+": "+JSON.stringify(created.error||created).slice(0,650));
const id=created.id||created.uid;
if(!id)throw new Error("Deployment response missing id");
console.log("MONEY_CONTROL_DEV_CREATED id="+id+" url="+created.url);

for(let i=0;i<90;i++){
  await new Promise(resolve=>setTimeout(resolve,3000));
  const statusResponse=await fetch("https://api.vercel.com/v13/deployments/"+encodeURIComponent(id)+"?teamId="+encodeURIComponent(teamId),{headers:auth});
  if(!statusResponse.ok)throw new Error("Inspect deployment "+id+" HTTP "+statusResponse.status);
  const status=await statusResponse.json();
  const state=status.readyState||status.state||"UNKNOWN";
  if(i===0||i%5===0||["READY","ERROR","CANCELED","BLOCKED"].includes(state))console.log("Money Control dev "+id+": "+state);
  if(state==="READY"){
    console.log("MONEY_CONTROL_DEV_READY id="+id+" url=https://"+(status.url||created.url)+"/money-control/");
    process.exit(0);
  }
  if(["ERROR","CANCELED","BLOCKED"].includes(state)){
    throw new Error("Money Control dev "+id+" failed state="+state+" code="+(status.errorCode||"")+" message="+(status.errorMessage||""));
  }
}
throw new Error("Money Control dev still pending");
