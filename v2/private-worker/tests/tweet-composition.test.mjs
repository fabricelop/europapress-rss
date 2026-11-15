import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const app=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
const start=app.indexOf("function xLength(value)");
const end=app.indexOf("// Server-side marks:",start);
const editorStart=app.indexOf("function editorial(raw)");
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
