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

test("La copia usa los píxeles visibles sin repetir la descarga remota",async()=>{
 const calls=[];
 const fakeCanvas={
  width:0,height:0,
  getContext(){return {drawImage(image,x,y){calls.push(["draw",image.naturalWidth,image.naturalHeight,x,y])}}},
  toBlob(callback,mime){calls.push(["blob",this.width,this.height,mime]);callback(new Blob(["png"],{type:mime}))}
 };
 const context={
  API:"/api/ttittulares-control",Promise,encodeURIComponent,Blob,
  document:{createElement(type){assert.equal(type,"canvas");return fakeCanvas}},
  fetch(){calls.push("fetch");throw new Error("La foto ya está disponible; no hay que descargarla")},
  console:{warn(){}}
 };
 vm.createContext(context);vm.runInContext(inline.slice(clipStart,clipEnd),context);
 const url="https://example.test/photo.webp";
 const preview={
  complete:true,naturalWidth:1600,naturalHeight:900,
  getAttribute(attr){assert.equal(attr,"src");return context.API+"?view=image-proxy&url="+encodeURIComponent(url)}
 };
 const blob=await context.imagePngBlob(url,preview);
 assert.equal(blob.type,"image/png");
 assert.deepEqual(calls,[["draw",1600,900,0,0],["blob",1600,900,"image/png"]]);
});
