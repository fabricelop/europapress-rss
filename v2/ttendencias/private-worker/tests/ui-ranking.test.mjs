import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname,join} from "node:path";

const base=join(dirname(fileURLToPath(import.meta.url)),"..");
const app=readFileSync(join(base,"web-source/app.js"),"utf8");
const built=readFileSync(join(base,"dist/app.js"),"utf8");
const index=readFileSync(join(base,"dist/index.html"),"utf8");
const css=readFileSync(join(base,"dist/styles.css"),"utf8");

const start=app.indexOf("function movementIndicator(item)");
const end=app.indexOf("\nfunction top30Since(item)",start);
assert.ok(start>=0&&end>start,"movement indicator is present in the private source");
const el=(tag,cls,value)=>({tag,className:cls,textContent:String(value),title:"",setAttribute(key,val){this[key]=val}});
const move=new Function("el",app.slice(start,end)+"\nreturn movementIndicator;")(el);

test("each private Top 30 rank displays the real previous-snapshot position delta",()=>{
 const up=move({rank:1,previous_rank:5,movement:"up"});
 assert.equal(up.textContent,"↑ 4");
 assert.match(up.className,/up/);
 const down=move({rank:8,previous_rank:5,movement:"down"});
 assert.equal(down.textContent,"↓ 3");
 assert.match(down.className,/down/);
 const same=move({rank:3,previous_rank:3,movement:"unchanged"});
 assert.equal(same.textContent,"—");
 assert.match(same.className,/same/);
 assert.equal(move({rank:1,previous_rank:null,movement:"entry"}).textContent,"Nueva");
 assert.equal(move({rank:1,previous_rank:null,movement:"short_return"}).textContent,"Vuelve");
 assert.equal(move({rank:1,previous_rank:null,movement:"reentry"}).textContent,"Vuelve");
 assert.equal(move({rank:1,previous_rank:null,movement:"baseline"}).textContent,"—");
});

test("private site shows entry date, explanation date, and full radar date",()=>{
 const since=app.indexOf("function top30Since(item)");
 const tail=app.indexOf("\nfunction render()",since);
 assert.ok(since>=0&&tail>since);
 assert.match(app.slice(since,tail),/entered_top30_at/);
 assert.match(app,/title\.append\(entered\)/);
 assert.match(app,/title\.append\(time\)/);
 assert.match(built,/function movementIndicator\(item\)/);
 assert.match(built,/function top30Since\(item\)/);
 assert.match(built,/updateRadar\(state\.captured\)/);
 assert.match(built,/weekday:"short"/);
 assert.match(css,/\.movement-indicator\.up/);
 assert.match(css,/\.movement-indicator\.down/);
 assert.match(css,/\.movement-indicator\.return/);
 assert.match(app,/Regresó el /);
 assert.match(index,/styles\.css/);
});

test("private app only loads state through its authorized Worker proxy",()=>{
 assert.match(built,/const BASE="\/api\/state\/"/);
 assert.doesNotMatch(built,/const BASE="https:\/\/raw\.githubusercontent\.com/);
 assert.doesNotMatch(built,/localStorage\.setItem\(MARKS_KEY/);
 assert.match(built,/\/api\/marks/);
});

test("R remains clickable in collapsed card without toggling its disclosure",()=>{
 const r=app.indexOf('const flag=el("button","red-toggle","R");');
 const end=app.indexOf('const body=el("div","explanation"',r);
 assert.ok(r>=0&&end>r,"R control is part of every Top30 item");
 const block=app.slice(r,end);
 assert.match(block,/event\.preventDefault\(\)/);
 assert.match(block,/event\.stopPropagation\(\)/);
 assert.match(block,/head\.append\(flag\)/);
 assert.doesNotMatch(block,/card\.append\(flag\)/);
 assert.match(css,/\.trend\.marked-red\{background:/);
 assert.match(css,/\.red-toggle\{position:static;flex:none/);
 assert.match(built,/head\.append\(flag\)/);
});

test("RE requested has visible pending state and hides previous explanation and image",()=>{
 assert.match(app,/function reResetPending\(item\)/);
 assert.match(app,/const reset=reResetPending\(item\)/);
 assert.match(app,/RE solicitada · reinicio pendiente/);
 assert.match(app,/En revisión · nueva explicación en preparación/);
 assert.match(app,/const time=reset\?null:explanationTime\(item\)/);
 assert.match(app,/if\(!reset&&\(imageReady\(item\)\|\|item\.image_suppressed===true\)\)/);
 assert.match(app,/if\(!reset\|\|item\.status!==\"explicada\"\)makePublishButtons\(card,item\)/);
 assert.match(app,/if\(!reset\)attachGeneratedImage\(card,item\)/);
 assert.match(css,/\.review-state/);
});

test("sticky Radar and PU header includes rolling 24-hour manual click history",()=>{
 assert.match(index,/id="top-bar"/);
 assert.match(index,/id="radar-time"/);
 assert.match(index,/id="publication-summary"/);
 assert.match(index,/id="publication-history"/);
 assert.match(css,/\.top-bar\{position:sticky;top:env\(safe-area-inset-top\)/);
 assert.match(css,/body\{min-height:100dvh;padding-top:env\(safe-area-inset-top\)\}/);
 assert.match(css,/main\{width:100%;padding:0 0 env\(safe-area-inset-bottom\)\}/);
 assert.doesNotMatch(css,/main\{[^}]*padding:env\(safe-area-inset-top\)/);
 assert.match(built,/function loadPublications\(\)/);
 assert.match(built,/dateStyle:"short",timeStyle:"medium"/);
 assert.match(built,/\/api\/publication-count/);
 assert.match(built,/const pu=el\("button","publish-action publication-mark-action","PU"\)/);
});

test("trend detail says whether automatic image retries remain or are blocked",()=>{
 const from=app.indexOf("function imageRetryHint(item){"),to=app.indexOf("\nfunction ",from+10);
 assert.ok(from>=0&&to>from);
 const el=(tag,className,message)=>({tag,className,textContent:message,setAttribute(){}});
 const hint=new Function("imageReady","el",app.slice(from,to)+";return imageRetryHint;")(()=>false,el);
 const row={status:"explicada",image_retry:{state:"retry_pending",remaining:2,pre_send_failures:1}};
 assert.match(hint(row).textContent,/reintento automático pendiente · 2 envíos disponibles/);
 assert.match(hint(row).textContent,/fallos previos al envío 1\/3/);
 assert.match(hint({...row,image_retry:{state:"exhausted"}}).textContent,/agotados/);
 assert.match(hint({...row,image_retry:{state:"blocked"}}).textContent,/no habrá más intentos automáticos/);
 assert.match(hint({...row,image_retry:{state:"unknown"}}).textContent,/No se puede confirmar/);
 assert.equal(hint({...row,status:"pendiente"}),null);
 assert.match(css,/\.image-retry-status\{/);
 assert.match(built,/const hint=imageRetryHint\(item\)/);
});

test("an explained trend without an image offers separate copy prompt and paste actions",()=>{
 const start=app.indexOf("function manualImagePrompt(item){");
 const end=app.indexOf("\nfunction showManualImagePrompt(",start);
 assert.ok(start>=0&&end>start,"manual image prompt builder is present");
 const generate=new Function(app.slice(start,end)+"\nreturn manualImagePrompt;")();
 const identity="trv2-cf011150bc27382a31b3a6d8";
 const result=generate({trend_id:identity,name:"Anticorrupción",revision:2,
  explanation:"Anticorrupción investiga posibles contratos de Defensa. La causa de la tendencia no está confirmada. " .repeat(2)});
 assert.match(result,/TT_V2_IMAGE_MANUAL_V1 trv2-cf011150bc27382a31b3a6d8-r2/);
 assert.match(result,/Usa ImageGen AHORA/);
 assert.match(result,/Tendencia: Anticorrupción/);
 assert.match(result,/TEXTO EDITORIAL YA EXPLICADO/);
 assert.match(result,/no representes hipótesis como hechos/);
 assert.match(result,/No publiques en redes ni modifiques GitHub/);
 assert.throws(()=>generate({trend_id:identity,revision:3,name:"Anticorrupción",explanation:"Corto"}),/explicación completa/);
 assert.match(app,/["']publish-action image-prompt-action["'],["']Copiar prompt IA["']/);
 assert.match(app,/["']publish-action image-gpt-action["'],["']GPT IMA["']/);
 assert.match(app,/images\.href='https:\/\/chatgpt\.com\/images\/'/);
 assert.match(app,/images\.target='_blank'/);
 assert.match(app,/images\.rel='noopener noreferrer'/);
 assert.match(app,/if\(!imageReady\(item\)&&item\.image_suppressed!==true\)\{/);
 assert.match(app,/["']publish-action image-paste-action["'],["']Pegar IA["']/);
 assert.match(app,/navigator\.clipboard\.writeText\(prompt\)/);
 assert.match(app,/showManualImagePrompt\(prompt,item\)/);
 assert.match(built,/function manualImagePrompt\(item\)/);
 assert.match(css,/\.image-prompt-action\{/);
 assert.match(css,/\.image-gpt-action\{/);
});

test("incident card permits RE-X hints independently of explained RE-X",()=>{
 assert.match(app,/if\(item\.status==="incidencia"\)/);
 assert.match(app,/openReXDialog\(item,async hints/);
 assert.match(app,/\/api\/incident-rex/);
 assert.match(app,/incidentRequested\(item\)/);
 assert.match(app,/if\(item\.status!=="explicada"\)return;/);
});


test("Antonio Recio dossier with character count extracts the X-ready lead",()=>{
 const start=app.indexOf("function withoutInternalProvenance(text)");
 const end=app.indexOf("\n// Server-side marks",start);
 assert.ok(start>=0&&end>start,"editorial parser and tweet formatter are present");
 const renderEditorial=new Function(app.slice(start,end)+"\nreturn {editorial,tweetText};")();
 const raw=[
  "Antonio Recio",
  "",
  "ESTADO_CAUSA: CONFIRMADA ESTADO_X: NO_NECESARIO",
  "",
  "Explicación principal — apta para X (139 caracteres)",
  "",
  "El estreno hoy de la temporada 17 de 'La que se avecina' en Prime Video devuelve a Antonio Recio al centro de la conversación.",
  "",
  "Qué ha ocurrido",
  "La causa está razonablemente acreditada: el lunes 16 de noviembre de 2026 se estrena en España la temporada 17."
 ].join("\n");
 assert.equal(renderEditorial.editorial(raw),
  "El estreno hoy de la temporada 17 de 'La que se avecina' en Prime Video devuelve a Antonio Recio al centro de la conversación.");
 const formatted=renderEditorial.tweetText(raw,{rank:8,name:"Antonio Recio",cause_status:"confirmada_declarada"});
 assert.match(formatted,/TT#8 ANTONIO RECIO es tendencia/);
 assert.match(formatted,/El estreno hoy de la temporada 17/);
 assert.doesNotMatch(formatted,/Explicación capturada; formato editorial pendiente/);
});

test("BUS-X is visible in the summary for all statuses and searches the literal trend name",()=>{
 assert.match(app,/const busX=el\("a","bus-x-link","BUS-X"\)/);
 assert.match(app,/encodeURIComponent\(item.name\)/);
 assert.match(app,/busX\.target="_blank"/);
 assert.match(app,/busX\.rel="noopener noreferrer"/);
 assert.match(app,/head\.append\(busX\)/);
 assert.match(css,/\.bus-x-link\{/);
});
test("pending and active trends offer RE and RE-X without exposing publishing controls",()=>{
 const code=app.slice(app.indexOf('function makePublishButtons(card,item){'),app.indexOf('\nfunction render()'));
 assert.match(code,/item\.status==="pendiente"\|\|item\.status==="en_elaboracion"/);
 assert.match(code,/appendEditorialReButtons\(editing,item\)/);
 assert.match(app,/function appendEditorialReButtons\(editing,item\)/);
 assert.match(app,/mode:"x",hints/);
});
