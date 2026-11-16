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
 assert.match(shown,/La causa concreta de la tendencia no está confirmada\./);
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
 assert.match(shown,/no está confirmada/);
 assert.doesNotMatch(shown,/es tendencia|Ficha editorial|Fuentes consultadas|example.org/);
 assert.ok(xLength(shown)<=280);
 assert.equal(publishableText(shown),true);
});
test('long adapted context cannot crowd out the uncertainty sentence',()=>{
 const raw='ESTADO_CAUSA: NO_CONFIRMADA\nQué sabemos\nEl festival anuncia hoy su nueva edición en Barcelona. '+
  'La programación ofrece numerosos conciertos y actividades con invitados de diferentes países. '.repeat(5);
 const shown=explanationText(raw,{rank:14,name:'Festival Internacional de Barcelona'});
 assert.match(shown,/El festival anuncia hoy su nueva edición en Barcelona\./);
 assert.match(shown,/La causa concreta de la tendencia no está confirmada\./);
 assert.ok(xLength(shown)<=280);
 assert.doesNotMatch(shown,/…|\.\.\./);
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
 const start=app.indexOf('function makePublishButtons(card,item){');
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
test('empty or unusable captures never expose the long dossier as an X draft',()=>{
 assert.equal(explanationText('',{}),'Explicación pendiente.');
 assert.equal(publishableText(tweetText('',{})),false);
 const raw='Ficha editorial\nESTADO_CAUSA: CONFIRMADA\nFuentes consultadas\nhttps://example.org/';
 assert.doesNotMatch(explanationText(raw,{}),/Ficha editorial|example.org/);
 assert.equal(publishableText(tweetText(raw,{})),false);
});
