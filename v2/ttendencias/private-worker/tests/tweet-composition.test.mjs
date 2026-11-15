import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const app=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
const start=app.indexOf("function xLength(value)");
const end=app.indexOf("// Server-side marks:",start);
const editorStart=app.indexOf("function withoutInternalProvenance(text)");
const editorEnd=app.indexOf("const WEB_URL=",editorStart);
assert.ok(start>0&&end>start&&editorEnd>editorStart);
const editorial=new Function(app.slice(editorStart,editorEnd)+"\nreturn editorial;")();
const {tweetText,xLength}=new Function("editorial","WEB_URL",
  app.slice(start,end)+"\nreturn {tweetText,xLength};")(editorial,"https://ttactualidad.rainyraven22.chatgpt.site/");

const answer=(prose,tags,joke)=>[
  "ESTADO_CAUSA: CONFIRMADA","Explicación periodística",
  prose,"",tags||"#Prueba #Elecciones29N #Debates",
  joke||"🌶️ Un remate que se debe conservar entero si cabe.",
].join("\n");

test("published text begins at TT# with real rank and uppercase name",()=>{
 const got=tweetText(answer("#OcultacionAntidemocratica circula en el contexto de las críticas por la ausencia de Podemos e Irene Montero en los debates electorales."),{rank:1,name:"#OcultacionAntidemocratica"});
 assert.match(got,/^TT#1 #OCULTACIONANTIDEMOCRATICA es tendencia porque circula en el contexto/);
 assert.match(got,/debates electorales\./);
 assert.ok(xLength(got)<=280);
 assert.doesNotMatch(got,/…|\.\.\./);
});

test("retain complete explanation, then entire punchline, then tags and URL when they fit",()=>{
 const prose="La primera frase es completa y cuenta un hecho acreditado por varias fuentes independientes.";
 const shortJoke="🌶️ Un remate.";
 const got=tweetText(answer(prose,"#Caso",shortJoke),{rank:11,name:"Ejemplo"});
 assert.match(got,/^TT#11 EJEMPLO es tendencia: La primera frase/);
 assert.ok(got.includes(prose));
 assert.ok(got.includes(shortJoke));
 assert.ok(got.includes("#Caso"));
 assert.ok(got.includes("https://ttactualidad.rainyraven22.chatgpt.site/"));
});

test("omit the lower priority elements whole, never half an explanation or a gag",()=>{
 const prose="El informe detalla hechos contrastados, antecedentes relevantes y las reacciones institucionales que siguieron al anuncio del domingo. La información se mantiene actualizada.";
 const joke="🌶️ Esta es una segunda línea de humor bastante larga que nunca debe aparecer cortada a mitad de una oración.";
 const got=tweetText(answer(prose,"#Uno #Dos #Tres #Cuatro #Cinco #Seis #Siete",joke),{rank:3,name:"Noticia muy relevante"});
 assert.ok(got.includes(prose),"the main explanation is completely retained");
 assert.ok(!got.includes("…"),"never append an ellipsis");
 assert.ok(!got.includes(joke)||got.includes(joke+"\n")||got.endsWith(joke),"no half a joke");
 assert.ok(xLength(got)<=280);
});

test("very long older material ends at a sentence boundary",()=>{
 const prose="Este texto explica un hecho verificado con el contexto imprescindible para entenderlo. "
  +"La segunda oración añade tantos detalles, nombres, fechas, declaraciones y antecedentes que resultaría muy larga para el límite de la red social, de modo que debe omitirse como unidad completa y no quedar a medias junto a un símbolo de elipsis. "
  +"La tercera frase no debe entrar.";
 const got=tweetText(answer(prose),{rank:27,name:"Ejemplo complejo"});
 assert.ok(got.includes("entenderlo."));
 assert.doesNotMatch(got,/…|\.\.\./);
 assert.ok(xLength(got)<=280);
});

test("strip internal editorial labels such as Remate suave from X and the list",()=>{
 const raw=["ESTADO_CAUSA: CONFIRMADA","Explicación periodística",
  "TT#18 ÁVILA es tendencia por el descarrilamiento de un tren de mercancías ocurrido en Zarzalejo.",
  "Remate suave: 🌶️ El tren a Ávila ha terminado necesitando un plan B por carretera.",
  "#Ávila #Zarzalejo #Renfe #Adif"].join("\n");
 const displayed=editorial(raw);
 const published=tweetText(raw,{rank:18,name:"Ávila"});
 assert.doesNotMatch(displayed,/Remate suave:/i);
 assert.doesNotMatch(published,/Remate suave:/i);
 assert.match(displayed,/🌶️ El tren a Ávila/);
 assert.match(published,/🌶️ El tren a Ávila/);
});

test("public-facing explanation does not name the internal TTActualidad V2 pipeline",()=>{
 const displayed=editorial(["Explicación periodística",
  "Weverse, la plataforma de comunicación entre artistas y seguidores, figura en la relación de tendencias españolas facilitada a TTActualidad V2.",
  "El grupo celebra este domingo un concierto que puede explicar parte del interés."].join("\n"));
 assert.match(displayed,/es tendencia en España/);
 assert.doesNotMatch(displayed,/TTActualidad V2/);
});

const dossier=(name,cause,lead,following)=>[
  `${name} — Ficha editorial`,
  "",`${cause} Solo LISTAS · Sin publicación automática`,
  "","15 de noviembre de 2026 · España", "","ESTADO_CAUSA: CONFIRMADA",
  "","ESTADO_X: NO_NECESARIO","","Explicación principal — apta para X",
  "Writing","",lead,"",following,"",
  "Una segunda parte de la ficha que no debe utilizarse como tuit.",
].join("\n");

test("Maledon: the V2 panel and P-X select the actual factual lead, not dossier metadata",()=>{
 const lead="Théo Maledon reaparece tras su lesión y brilla con 18 puntos y 29 de valoración en la victoria del Real Madrid ante Baskonia (84-98).";
 const raw=dossier("Maledon","Causa identificada y contrastada",lead,"¿Por qué es tendencia?");
 const shown=editorial(raw),post=tweetText(raw,{rank:13,name:"Maledon"});
 assert.equal(shown,lead);
 assert.ok(post.startsWith(`TT#13 MALEDON es tendencia: ${lead}`));
 assert.ok(xLength(post)<=280);
 assert.doesNotMatch(post,/Solo LISTAS|Ficha editorial|Writing|Explicación principal|Sin publicación automática/i);
});

test("Damian Jones: prioritise the recorded summary over the 'Causa de la tendencia' section",()=>{
 const lead="Damian Jones brilla con 18 puntos y 21 de valoración en la victoria del Real Madrid ante Baskonia (84-98), que mantiene invicto al equipo blanco en Liga.";
 const raw=dossier("Damian Jones","Causa identificada y contrastada",lead,"Causa de la tendencia");
 assert.equal(editorial(raw),lead);
 const post=tweetText(raw,{rank:14,name:"Damian Jones"});
 assert.match(post,/^TT#14 DAMIAN JONES es tendencia porque brilla con 18 puntos y 21 de valoración/);
 assert.ok(xLength(post)<=280);
 assert.doesNotMatch(post,/Causa identificada|Solo LISTAS|Explicación principal/);
});

test("Ontiveros: preserve an unconfirmed causal link, never promote it to a fact",()=>{
 const lead="Javi Ontiveros participa en la jugada del empate del Cádiz ante el Eibar (1-1). El partido podría explicar su tendencia, pero no está confirmado.";
 const raw=dossier("Ontiveros","Causa probable, no confirmada",lead,"Qué ha ocurrido")
  .replace("ESTADO_CAUSA: CONFIRMADA","ESTADO_CAUSA: NO_CONFIRMADA");
 assert.equal(editorial(raw),lead);
 const post=tweetText(raw,{rank:18,name:"Ontiveros"});
 assert.match(post,/participa en la jugada del empate/);
 assert.match(post,/podría explicar su tendencia, pero no está confirmado/);
 assert.doesNotMatch(post,/Solo LISTAS|Causa probable|Sin publicación automática|Explicación principal/);
 assert.ok(xLength(post)<=280);
});

test("if a dossier has no usable editorial lead, fail closed instead of publishing boilerplate",()=>{
 const raw=["Maledon — Ficha editorial","Causa identificada y contrastada Solo LISTAS · Sin publicación automática",
  "15 de noviembre de 2026 · España","ESTADO_CAUSA: CONFIRMADA","Explicación principal — apta para X",
  "Writing","","¿Por qué es tendencia?","Datos adicionales no listos."].join("\n");
 assert.equal(editorial(raw),"Explicación capturada; formato editorial pendiente de adaptar.");
 assert.match(tweetText(raw,{rank:13,name:"Maledon"}),/^Explicación capturada/);
});
