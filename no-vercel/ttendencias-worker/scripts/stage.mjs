import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const current=path.dirname(fileURLToPath(import.meta.url));
const workerRoot=path.resolve(current,"..");
const repositoryRoot=path.resolve(workerRoot,"../..");
const target=path.join(workerRoot,"generated");
const libOut=path.join(target,"lib");
const assetsOut=path.join(target,"assets");
fs.mkdirSync(libOut,{recursive:true});
fs.mkdirSync(path.join(target,"compat"),{recursive:true});
const names=[
  "ttendencias-control-handler.js",
  "ttendencias-run-handler.js",
  "ttendencias-run-status-handler.js",
  "ttendencias-copy-state.js",
  "ttendencias-remate-ratings.js"
];
for(const name of names){
  let code=fs.readFileSync(path.join(repositoryRoot,"vercel-webhook","lib",name),"utf8");
  code=code.replace(/import sharp from ["']sharp["'];/g,'import sharp from "../compat/sharp.js";');
  code=code.replace(/import webpush from ["']web-push["'];/g,'import webpush from "../compat/web-push.js";');
  fs.writeFileSync(path.join(libOut,name),code);
}
for(const name of ["sharp.js","web-push.js"]){
  fs.copyFileSync(path.join(workerRoot,"src","compat",name),path.join(target,"compat",name));
}
const webSrc=path.join(repositoryRoot,"vercel-webhook","ttendencias");
fs.cpSync(webSrc,path.join(assetsOut,"ttendencias"),{recursive:true,force:true});
const original=`await navigator.clipboard.write([new ClipboardItem({"image/png":await rr.blob()})]);`;
const adapted=`const sourceBlob=await rr.blob();
   const bitmap=await createImageBitmap(sourceBlob);
   try{
     const canvas=document.createElement("canvas");canvas.width=bitmap.width;canvas.height=bitmap.height;
     canvas.getContext("2d").drawImage(bitmap,0,0);
     const png=await new Promise((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(Error("No se pudo convertir la imagen a PNG.")),"image/png"));
     await navigator.clipboard.write([new ClipboardItem({"image/png":png})]);
   }finally{bitmap.close?.()}`;
for(const page of ["explicadas","historico"]){
  const htmlFile=path.join(assetsOut,"ttendencias",page,"index.html");
  let html=fs.readFileSync(htmlFile,"utf8");
  if(!html.includes(original))throw Error("El botón Copiar imagen ha cambiado en "+page+". Revisar manualmente.");
  html=html.replace(original,adapted);
  html=html.replace('API+"?view=image-proxy&format=png&url="','API+"?view=image-proxy&url="');
  fs.writeFileSync(htmlFile,html);
}
console.log("TTendencias staged: "+names.length+" original controllers/helpers + same PWA pages, independent Cloudflare adapter.");
