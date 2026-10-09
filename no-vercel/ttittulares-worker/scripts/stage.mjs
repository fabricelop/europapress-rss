import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const repo=path.resolve(root,"../..");
const generated=path.join(root,"generated");
const lib=path.join(generated,"lib");
const assets=path.join(generated,"assets");
fs.mkdirSync(lib,{recursive:true});
fs.mkdirSync(path.join(generated,"compat"),{recursive:true});
for(const name of [
  "ttittulares-control-handler.js",
  "ttittulares-run-handler.js",
  "ttittulares-run-status-handler.js",
  "ttittulares-remate-ratings.js"
]){
  let code=fs.readFileSync(path.join(repo,"vercel-webhook","lib",name),"utf8");
  code=code.replace(/import sharp from ["']sharp["'];/g,'import sharp from "../compat/sharp.js";');
  fs.writeFileSync(path.join(lib,name),code);
}
fs.copyFileSync(path.join(root,"src","compat","sharp.js"),path.join(generated,"compat","sharp.js"));
const input=path.join(repo,"vercel-webhook","ttittulares");
const output=path.join(assets,"ttittulares");
fs.cpSync(input,output,{recursive:true,force:true});
// PWA cards reference /tt-shared/*; deploy these assets to THIS Worker origin.
const sharedInput=path.join(repo,"vercel-webhook","tt-shared");
const sharedOutput=path.join(assets,"tt-shared");
fs.cpSync(sharedInput,sharedOutput,{recursive:true,force:true});
for(const name of ["gag-actions.js","gag-actions.css"]){
  if(!fs.statSync(path.join(sharedOutput,name)).isFile())throw Error("Shared GAG asset missing: "+name);
}
for(const pathName of ["index.html","sw.js","manifest.webmanifest","icon.svg"]){
  if(!fs.statSync(path.join(output,pathName)).isFile())throw Error("Asset missing: "+pathName);
}
console.log("TTiTTulares staged: 4 legacy handlers + original PWA, isolated Cloudflare Worker");
