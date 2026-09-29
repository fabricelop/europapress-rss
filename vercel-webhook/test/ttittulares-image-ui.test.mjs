import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const html=readFileSync(new URL("../ttittulares/index.html",import.meta.url),"utf8");
const inline=html.match(/<script>([\s\S]*?)<\/script>/i)?.[1]||"";
const clipStart=inline.indexOf("async function imagePngBlob(url){");
const clipEnd=inline.indexOf("function mountRemateRating(",clipStart);

test("El refresco no destruye imágenes que ya están cargadas",()=>{
 assert.match(inline,/lastRenderedView==="ready"&&lastReadyRendering===signature\)return/);
 assert.match(inline,/preservedImages\.set\(JSON\.stringify\(\[card\.dataset\.eventId,url\]\),preview\)/);
 assert.match(inline,/preview\.replaceWith\(previous\)/);
 assert.match(inline,/preview\.getAttribute\("src"\)!==proxySrc\)preview\.src=proxySrc/);
});
test("La petición al portapapeles sucede antes de acabar la descarga",async()=>{
 assert.ok(clipStart>=0&&clipEnd>clipStart);
 const calls=[],messages=[];
 let resolveFetch;
 const pending=new Promise(resolve=>{resolveFetch=resolve});
 const context={
  API:"/api/ttittulares-control",
  navigator:{clipboard:{write(items){calls.push("write");return Promise.resolve(items[0].data["image/png"])}}},
  ClipboardItem:class{constructor(data){this.data=data;calls.push("item")}},
  fetch(){calls.push("fetch");return pending},
  encodeURIComponent,Blob,Promise,toast(t){messages.push(t)},console:{error(){}}
 };
 vm.createContext(context);vm.runInContext(inline.slice(clipStart,clipEnd),context);
 const button={disabled:false,textContent:"Copiar imagen"};
 context.copyImageToClipboard("https://example.test/photo.png",button);
 assert.deepEqual(calls,["fetch","item","write"]);
 assert.equal(button.disabled,true);
 resolveFetch({ok:true,blob:async()=>new Blob(["image"],{type:"image/png"})});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(button.disabled,false);
 assert.equal(button.textContent,"Copiar imagen");
 assert.ok(messages.some(x=>x.includes("copiada")));
});
test("Si falla la descarga, restaurar el botón sin fingir que copió",async()=>{
 const messages=[];
 const context={
  API:"/api/ttittulares-control",
  navigator:{clipboard:{write(items){return Promise.resolve(items[0].data["image/png"])}}},
  ClipboardItem:class{constructor(data){this.data=data}},
  fetch:async()=>({ok:false,status:503}),
  encodeURIComponent,Blob,Promise,toast(t){messages.push(t)},console:{error(){}}
 };
 vm.createContext(context);vm.runInContext(inline.slice(clipStart,clipEnd),context);
 const button={disabled:false,textContent:"Copiar imagen"};
 context.copyImageToClipboard("https://example.test/photo.png",button);
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(button.disabled,false);
 assert.ok(messages.some(x=>x.includes("No se pudo copiar")));
 assert.ok(!messages.some(x=>x.includes("copiada")));
});
