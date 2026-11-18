import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app=readFileSync(new URL('../web-source/app.js',import.meta.url),'utf8');
const code=app.slice(app.indexOf('function withoutInternalProvenance(text)'),app.indexOf('// Server-side marks:'));
const {editorial,tweetText,explanationText,publishableText,xLength}=new Function(code+';return {editorial,tweetText,explanationText,publishableText,xLength};')();
const tem=JSON.parse(readFileSync(new URL('./fixtures/tem16n.json',import.meta.url),'utf8'));
test('TEM16N real capture becomes short publishable X copy, identical in V2',()=>{
 const shown=explanationText(tem.explanation,tem);
 assert.equal(shown,tweetText(tem.explanation,tem));
 assert.match(shown,/^TT#7 #TEM16N:/);
 assert.match(shown,/conversación televisiva sobre «Todo es mentira»/);
 assert.doesNotMatch(shown,/La causa concreta de la tendencia no está confirmada\./);
 assert.ok(xLength(shown)<=280);
 assert.equal(publishableText(shown),true);
 assert.doesNotMatch(shown,/formato editorial pendiente|ESTADO_|Ficha editorial|Qué sabemos|Fuentes|403|15:30|19:00/);
});
test('other dossier topics adapt from their own text without leaking the full file',()=>{
 const raw='Otro tema — Ficha editorial\nESTADO_CAUSA: NO_CONFIRMADA\nExplicación principal — apta para X\nQué sabemos\n\n'+
  'El festival anuncia su nueva edición en Barcelona, con actuaciones de varios artistas durante el próximo verano.\n\nFuentes consultadas\nhttps://example.org/';
 const item={rank:4,name:'Festival'};
 const shown=explanationText(raw,item);
 assert.equal(shown,tweetText(raw,item));
 assert.match(shown,/El festival anuncia su nueva edición/);
 assert.doesNotMatch(shown,/no está confirmada/);
 assert.doesNotMatch(shown,/es tendencia|Ficha editorial|Fuentes consultadas|example.org/);
 assert.ok(xLength(shown)<=280);
 assert.equal(publishableText(shown),true);
});
test('long adapted context keeps verified facts without a repetitive uncertainty ending',()=>{
 const raw='ESTADO_CAUSA: NO_CONFIRMADA\nQué sabemos\nEl festival anuncia hoy su nueva edición en Barcelona. '+
  'La programación ofrece numerosos conciertos y actividades con invitados de diferentes países. '.repeat(5);
 const shown=explanationText(raw,{rank:14,name:'Festival Internacional de Barcelona'});
 assert.match(shown,/El festival anuncia hoy su nueva edición en Barcelona\./);
 assert.doesNotMatch(shown,/La causa concreta de la tendencia no está confirmada\./);
 assert.doesNotMatch(shown,/es tendencia:/);
 assert.ok(xLength(shown)<=280);
 assert.doesNotMatch(shown,/…|\.\.\./);
});
test('Piqué: remove the repetitive no se confirma que impulsa la tendencia suffix only',()=>{
 const item={rank:12,name:'Piqué',cause_status:'no_confirmada'};
 const raw='ESTADO_CAUSA: NO_CONFIRMADA\nExplicación principal — apta para X\n'+
  'Piqué reaparece en la conversación por sus declaraciones sobre el fútbol español. No se confirma que impulsa la tendencia.\n'+
  '\nFuentes consultadas\nhttps://example.org/';
 const result=explanationText(raw,item);
 assert.match(result,/PIQUÉ: reaparece en la conversación/);
 assert.doesNotMatch(result,/No se confirma que impulsa la tendencia/);
 assert.doesNotMatch(result,/es tendencia:/);
 assert.ok(xLength(result)<=280);
 const legitimate='Piqué reaparece en la conversación. No se confirma la identidad del denunciante.';
 assert.match(explanationText('ESTADO_CAUSA: NO_CONFIRMADA\nExplicación principal — apta para X\n'+legitimate+'\n\nFuentes',item),/No se confirma la identidad del denunciante/);
});
test('Markdown headings and writing blocks preserve the recognised lead',()=>{
 const lead='El estreno de la nueva temporada devuelve al personaje al centro de la conversación pública.';
 const raw='ESTADO_CAUSA: CONFIRMADA\n### **Explicación principal — apta para X (100 caracteres)**\n:::writing{variant="social_post"}\n'+lead+'\n:::\n\n## Qué sabemos\nOtro contexto.';
 assert.equal(editorial(raw),lead);
 assert.equal(publishableText(tweetText(raw,{rank:8,name:'Antonio Recio'})),true);
 assert.doesNotMatch(explanationText(raw,{rank:8,name:'Antonio Recio'}),/:::|\*\*|Qué sabemos/);
});
test('V2 and the actual X intent use the same adapted copy with enabled P-X',()=>{
 const buttons=[];
 const el=(tag,className,text)=>{const n={tag,className,text,children:[],disabled:false,handlers:{},setAttribute(){},append(...nodes){this.children.push(...nodes);},addEventListener(type,fn){this.handlers[type]=fn;}};buttons.push(n);return n;};
 const start=app.indexOf('function appendEditorialReButtons(editing,item){');
 const end=app.indexOf('\nfunction render(){',start);
 let opened;
 const make=new Function('el','imageReady','reRequested','tweetText','publishableText','window',
  app.slice(start,end)+';return makePublishButtons;')(el,()=>false,()=>false,tweetText,publishableText,{open(url){opened=url;return {};}});
 const card=el('div');make(card,tem);
 const px=buttons.find(b=>b.text==='P-X');
 assert.ok(px);assert.equal(px.disabled,false);
 px.handlers.click();
 assert.equal(new URL(opened).searchParams.get('text'),explanationText(tem.explanation,tem));
 assert.match(app,/item.status==="explicada"\?explanationText\(item.explanation,item\)/);
});

test('Fnatic: recognize “Explicación principal para X (155 caracteres máximo)”',()=>{
 const lead='Fnatic podría ser tendencia por su partido de Counter-Strike 2 contra 100 Thieves en la fase clasificatoria del PGL Cluj-Napoca 2027. #CS2 #Fnatic';
 const raw=[
  'Fnatic — ficha informativa','',
  'Causa no confirmada','',
  'Explicación principal para X (155 caracteres máximo):','',
  lead,'',
  'Investigación y contraste','Causa confirmada',
  'El motivo informativo está acreditado por varias fuentes independientes.'
 ].join('\n');
 const item={rank:13,name:'Fnatic',cause_status:'confirmada_declarada'};
 assert.equal(editorial(raw),lead);
 const shown=explanationText(raw,item);
 assert.equal(shown,tweetText(raw,item));
 assert.doesNotMatch(shown,/Explicación capturada|formato editorial pendiente|ficha informativa|Investigación y contraste/i);
 assert.match(shown,/FNATIC podría ser tendencia por su partido de Counter-Strike 2/);
 assert.ok(xLength(shown)<=280);
 assert.equal(publishableText(shown),true);
});
test('alternate X lead headings with “texto apto para X” are also recognized',()=>{
 const samples=[
  ['Apple','Explicación principal — texto apto para X','Apple presenta una nueva función de privacidad para sus dispositivos y actualiza sus sistemas operativos.'],
  ['Albania','Explicación principal — texto apto para X (máximo 155 caracteres)','Albania se clasifica para la fase final tras ganar el encuentro decisivo de la eliminatoria europea.'],
  ['Miguel Ángel Blanco','Explicación principal — texto apto para X (155 caracteres máximo)','El aniversario del secuestro y asesinato de Miguel Ángel Blanco vuelve a centrar actos de recuerdo y homenajes.']
 ];
 for(const [name,heading,lead] of samples){
  const raw=[name+' — ficha informativa','',heading+':','',lead,'','Investigación y contraste','Fuentes consultadas'].join('\n');
  assert.equal(editorial(raw),lead,name);
  const shown=explanationText(raw,{rank:9,name,cause_status:'confirmada_declarada'});
  assert.doesNotMatch(shown,/formato editorial pendiente|Investigación y contraste/i,name);
  assert.ok(xLength(shown)<=280,name);
 }
});

test('empty or unusable captures never expose the long dossier as an X draft',()=>{
 assert.equal(explanationText('',{}),'Explicación pendiente.');
 assert.equal(publishableText(tweetText('',{})),false);
 const raw='Ficha editorial\nESTADO_CAUSA: CONFIRMADA\nFuentes consultadas\nhttps://example.org/';
 assert.doesNotMatch(explanationText(raw,{}),/Ficha editorial|example.org/);
 assert.equal(publishableText(tweetText(raw,{})),false);
});

test('LISTAS dossier headings yield X copy for EEUU and Estados Unidos',()=>{
 for(const [name,lead] of [
  ['EEUU','EEUU concentra actualidad internacional por las consecuencias de las elecciones legislativas estadounidenses.'],
  ['Estados Unidos','Estados Unidos vuelve a concentrar atención informativa en España, con noticias sobre Ucrania y relaciones internacionales.']
 ]){
  const raw=`TTActualidad V2 — Ficha editorial\nESTADO_CAUSA: NO_CONFIRMADA\nExplicación periodística — LISTAS\n\n${lead}\n\nFuentes HTTPS\nhttps://example.org/`;
  const shown=explanationText(raw,{rank:9,name,cause_status:'no_confirmada'});
  assert.match(shown,/^TT#9 /);
  assert.doesNotMatch(shown,/formato editorial pendiente|Ficha editorial|Fuentes HTTPS|example.org/);
  assert.ok(xLength(shown)<=280);
 }
});
test('texto editorial propuesto yields X copy without changing source dossier',()=>{
 const raw='Ficha editorial\nESTADO_CAUSA: NO_CONFIRMADA\nExplicación periodística — LISTAS\nContexto corto.\n\nTexto editorial propuesto\nWriting\n«Día de partido» aparece en España durante una jornada con encuentros de Segunda División, Liga F y Nations League.\n\nVerificación de X\nNo comprobada.';
 const shown=explanationText(raw,{rank:9,name:'día de partido',cause_status:'no_confirmada'});
 assert.match(shown,/TT#9 DÍA DE PARTIDO/);
 assert.doesNotMatch(shown,/formato editorial pendiente|Verificación de X|Writing/);
 assert.ok(xLength(shown)<=280);
 assert.match(raw,/Texto editorial propuesto/);
});

test('#codigo10: flattened research dossier shows only its X-ready explanation',()=>{
 const raw='#codigo10 — ficha de investigación Hipótesis informativa principal — apta para X Writing '+
  '#codigo10 podría ser tendencia por la emisión de una nueva entrega del programa de sucesos de Cuatro, presentado por Nacho Abad y David Aleman. '+
  '#codigo10 #Código10 Qué ha ocurrido El programa ha tratado distintos sucesos esta semana. Fuentes consultadas https://example.org/';
 const item={rank:12,name:'#codigo10',cause_status:'no_confirmada'};
 const lead='#codigo10 podría ser tendencia por la emisión de una nueva entrega del programa de sucesos de Cuatro, presentado por Nacho Abad y David Aleman.';
 assert.equal(editorial(raw),lead+' #codigo10 #Código10');
 const shown=explanationText(raw,item);
 assert.equal(shown,tweetText(raw,item));
 assert.match(shown,/^TT#12 #CODIGO10 podría ser tendencia por la emisión/);
 assert.doesNotMatch(shown,/ficha de investigaci[oó]n|Hip[oó]tesis informativa|apta para X|Writing|Qu[eé] ha ocurrido|Fuentes|example\.org/iu);
 assert.ok(xLength(shown)<=280);
 assert.equal(publishableText(shown),true);
});

test('inline X heading works for other trends and does not expose research metadata',()=>{
 for(const heading of ['Explicación principal — apta para X','Hipótesis informativa principal — apta para X']){
  const raw=`Otro tema — ficha de investigación ${heading} Writing El festival anuncia su regreso a Madrid con una nueva edición y conciertos durante todo el fin de semana.`;
  const result=explanationText(raw,{rank:5,name:'Festival',cause_status:'no_confirmada'});
  assert.match(result,/El festival anuncia su regreso a Madrid/,heading);
  assert.doesNotMatch(result,/ficha de investigaci[oó]n|Hip[oó]tesis informativa|Explicaci[oó]n principal|Writing/iu,heading);
  assert.ok(xLength(result)<=280,heading);
 }
});

test('unsafe or unrecognised dossier metadata never becomes display or P-X copy',()=>{
 const unsafe='— ficha de investigación Hipótesis informativa principal sobre este asunto: '+
  'El debate suscita nuevas reacciones en España durante toda la jornada y continúa en diferentes programas.';
 const result=explanationText(unsafe,{rank:3,name:'Debate'});
 assert.equal(result,'Explicación capturada; formato editorial pendiente de adaptar.');
 assert.equal(publishableText(result),false);
 assert.doesNotMatch(result,/ficha de investigaci[oó]n|Hip[oó]tesis informativa/i);
 const ordinary='El festival reúne a miles de aficionados durante una semana de conciertos. #Festival #Música';
 assert.match(explanationText(ordinary,{rank:7,name:'Festival'}),/#Festival #Música/);
});
