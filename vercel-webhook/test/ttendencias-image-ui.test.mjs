import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const html=readFileSync(new URL("../ttendencias/explicadas/index.html",import.meta.url),"utf8");
const inline=html.match(/<script>([\s\S]*?)<\/script>/i)?.[1]||"";

test("TTendencias reserva Gag IA para ImageGen del chat ejecutor",()=>{
 const start=inline.indexOf("function isChatImageGen(image){");
 const end=inline.indexOf("function appendImagePreview(",start);
 assert.ok(start>=0&&end>start);
 const context={};vm.createContext(context);vm.runInContext(inline.slice(start,end),context);
 const guard={version:3,scope:"current_item_only"};
 assert.equal(context.isChatImageGen({generated:true,provider:"chat-imagegen",origin:"executing_chat",context_guard:guard}),true);
 assert.equal(context.isChatImageGen({generated:true,provider:"chat-svg",origin:"executing_chat",context_guard:guard}),false);
 assert.equal(context.isChatImageGen({generated:true,provider:"vercel-openai",origin:"external",context_guard:guard}),false);
});

test("La vista filtra ai_image antes de mostrar la etiqueta Gag IA",()=>{
 assert.match(inline,/ai=isChatImageGen\(rawAi\)\?rawAi:\{\}/);
 assert.match(inline,/appendImagePreview\(grid,ai,"Gag IA",imageChoice==="ai"\)/);
});


const mainHtml=readFileSync(new URL("../ttendencias/index.html",import.meta.url),"utf8");
const runApi=readFileSync(new URL("../api/ttendencias-run.js",import.meta.url),"utf8");
const statusApi=readFileSync(new URL("../api/ttendencias-run-status.js",import.meta.url),"utf8");

test("Pendientes selecciona manualmente los gags por id y revisión",()=>{
 assert.match(html,/id="runImages"/);
 assert.match(html,/ttendencias-image-selected-v1/);
 assert.match(inline,/function imageSelectionKey\(x\)/);
 assert.match(inline,/selected\.has\(imageSelectionKey\(x\)\)/);
 assert.match(inline,/makeImageSelector\(x,false\)/);
});

test("El atajo Imágenes comparte la selección de Pendientes",()=>{
 assert.match(mainHtml,/id="runImages"/);
 assert.match(mainHtml,/ttendencias-image-selected-v1/);
 assert.match(mainHtml,/selected\.has\(mainImageSelectionKey\(x\)\)/);
 assert.match(mainHtml,/runImagesShortcut\.onclick=requestMainPendingImages/);
});

test("Política y meteorología sin víctimas no bloquean ImageGen",()=>{
 for(const source of [html,mainHtml,runApi,statusApi]){
   assert.match(source,/political_actor/);
   assert.match(source,/political_context/);
   assert.match(source,/safety_sensitive_weather/);
 }
 assert.doesNotMatch(runApi,/\|\|row\.with_image===false/);
 assert.doesNotMatch(statusApi,/\|\|row\.with_image===false/);
});

test("El job manual congela explicación y remate",()=>{
 assert.match(runApi,/context_snapshot=\{/);
 assert.match(runApi,/explanation:String\(row\.explanation/);
 assert.match(runApi,/closer_text:String\(row\.closer_text/);
 assert.match(runApi,/chat_command_version:3/);
 assert.match(runApi,/reason:"revision_changed"/);
});

test("Reexplicar desde Pendientes no fuerza with_image false",()=>{
 const start=inline.indexOf("async function sendReexplain()");
 const end=inline.indexOf("async function imageDecision",start);
 const block=inline.slice(start,end);
 assert.doesNotMatch(block,/with_image:false/);
});
