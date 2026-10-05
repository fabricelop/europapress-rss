import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html=fs.readFileSync(new URL("../ttittulares/index.html",import.meta.url),"utf8");
const script=html.match(/<script>([\s\S]*?)<\/script>/)?.[1]||"";
const control=fs.readFileSync(new URL("../api/ttittulares-control.js",import.meta.url),"utf8");
const runStatus=fs.readFileSync(new URL("../api/ttittulares-run-status.js",import.meta.url),"utf8");
new vm.Script(script);

test("Listas conserva acciones esenciales",()=>{
  assert.match(html,/📋 Copiar tuit/);
  assert.match(html,/✓ Ya publicado/);
  assert.match(html,/Desestimar/);
  assert.match(script,/close\("published","¿Confirmas que ya has publicado esta noticia\?"\)/);
  assert.match(script,/close\("dismiss","¿Desestimar esta noticia\?"\)/);
});

test("alta manual solo noticia e instrucciones",()=>{
  assert.ok(!html.includes("submitUrl"));
  assert.match(html,/placeholder="Noticia" required/);
  assert.match(script,/api\("submit",\{title,instruction\}\)/);
});

test("TTendencias queda desacoplado de TTiTTulares",()=>{
  assert.match(html,/No comprobadas/);
  assert.ok(!html.includes(">Tendencias</button>"));
  assert.ok(!html.includes("promote-trend"));
  assert.ok(!control.includes("TREND_CANDIDATES"));
  assert.ok(!control.includes("promoteTrendCandidate"));
  assert.match(control,/trend_candidates_count:0,trend_candidates:\[\]/);
});

test("el panel muestra el motivo de un error terminal",()=>{
  assert.match(html,/id="runErrorDetail"/);
  assert.match(script,/Qué pasó:/);
  assert.match(script,/Qué hacer:/);
  assert.match(runStatus,/ensureErrorIncident/);
  assert.match(runStatus,/pc_failure_detail/);
});

test("Tremending es solo una bandeja de lectura",()=>{
  assert.match(script,/Tremending · lectura/);
  assert.match(script,/Abrir artículo/);
  assert.match(script,/del\.textContent="Borrar"/);
  assert.match(script,/api\("delete-tremending",\{entry_id:item\.id\}\)/);
  assert.ok(!script.includes('api("send-tremending"'));
  assert.ok(!script.includes('api("select-tremending-tweet"'));
  assert.ok(!script.includes('api("postpone-tremending"'));
  assert.ok(!script.includes("→ TTiTTulares"));
  assert.ok(!script.includes("→ TTendencias"));
});

test("Borrar Tremending quita el item y evita que vuelva",()=>{
  const base=control.slice(control.indexOf("function idOf("),control.indexOf("function normalizedTitle("));
  const helpers=control.slice(control.indexOf("function tremendingEntryId("),control.indexOf("function threeSourceSpeedMinutes("));
  const ctx={URL,Set,Date};vm.createContext(ctx);vm.runInContext(base+"\n"+helpers,ctx);
  const url="https://www.publico.es/tremending/prueba-borrado.html";
  const doc={items:[{id:"tremending-test",url}],scan:{seen_urls:[]}};
  const result=ctx.deleteTremendingFromDoc(doc,"tremending-test","2026-10-05T15:00:00Z");
  assert.equal(result.doc.items.length,0);
  assert.equal(result.doc.scan.seen_urls.includes(url),true);
  assert.equal(result.doc.scan.deleted_count,1);
});

test("Salidas recientes excluye descartes manuales y conserva descartes con causa",()=>{
  const helpers=control.slice(control.indexOf("function tremendingEntryId("),control.indexOf("function threeSourceSpeedMinutes("));
  const ctx={Set,Date};vm.createContext(ctx);vm.runInContext("function idOf(v){return String(v||'').trim()}\nfunction canonicalUrl(v){return String(v||'')}\n"+helpers,ctx);
  assert.equal(ctx.processingOutcomeVisible({status:"DISMISSED"},{status:"dismissed",decision_source:"web_user"}),false);
  assert.equal(ctx.processingOutcomeVisible({status:"DISMISSED"},{status:"dismissed",decision_source:"telegram_emergency_callback"}),false);
  assert.equal(ctx.processingOutcomeVisible({status:"DISMISSED",problem_reason:"insufficient_independent_corroboration"},{}),true);
  assert.equal(ctx.processingOutcomeVisible({status:"SKIPPED_DUPLICATE",reconciliation_reason:"duplicada"},{}),true);
  assert.match(control,/manual_user_dismissed=true/);
  assert.match(control,/history_hidden_source="web_user_dismissal"/);
});

test("Tremending usa lectura autoritativa tras borrar y oculta borrados locales",()=>{
  assert.match(control,/fresh\?readJson\(TREMENDING\):readPublicJson\(TREMENDING\)/);
  assert.match(script,/TREMENDING_DELETED_KEY/);
  assert.match(script,/tremendingDeleted\.add\(id\)/);
  assert.match(script,/filter\(x=>!tremendingDeleted\.has\(String\(x\.id\|\|""\)\)\)/);
});
