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
