import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

test("future editorial prompts prioritize the news instead of trending-cause cliches",()=>{
 const source=readFileSync(new URL("../../editorial_run_v2.py",import.meta.url),"utf8");
 assert.match(source,/No desperdicies el titular ni los 155 caracteres en muletillas/);
 assert.match(source,/usa un condicional aplicado al hecho solo cuando sea necesario, sin certificar la causa/);
 assert.doesNotMatch(source,/usa fórmulas breves y naturales como 'Podría ser tendencia por/);
});
