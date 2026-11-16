import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app=readFileSync(new URL('../web-source/app.js',import.meta.url),'utf8');
const code=app.slice(app.indexOf('function withoutInternalProvenance(text)'),app.indexOf('// Server-side marks:'));
const {editorial,tweetText,explanationText,publishableText}=new Function(code+';return {editorial,tweetText,explanationText,publishableText};')();
const tem=JSON.parse(readFileSync(new URL('./fixtures/tem16n.json',import.meta.url),'utf8'));
test('TEM16N actual capture: display full dossier, preserving uncertainty and sources',()=>{
 const shown=explanationText(tem.explanation,tem);
 assert.match(shown,/La hipótesis televisiva tiene fundamento/);
 assert.match(shown,/no demuestra que el hashtag corresponda/);
 assert.match(shown,/X ha devuelto un error 403/);
 assert.match(shown,/https:\/\/x.com\/search/);
 assert.doesNotMatch(shown,/formato editorial pendiente|ESTADO_CAUSA|ESTADO_X/);
 assert.equal(publishableText(tweetText(tem.explanation,tem)),false);
});
test('unknown future dossier headings remain readable without becoming tweet copy',()=>{
 const raw='Un formato nuevo — Ficha editorial\nExplicación principal — apta para X\nQué sabemos\n\n'+
  'El acontecimiento coincide con la conversación, pero su relación causal sigue sin verificarse.\n\nFuentes consultadas\nhttps://example.org/';
 const shown=explanationText(raw,{rank:1,name:'Prueba'});
 assert.match(shown,/su relación causal sigue sin verificarse/);
 assert.match(shown,/https:\/\/example.org/);
 assert.equal(publishableText(tweetText(raw,{rank:1,name:'Prueba'})),false);
});
test('Markdown headings and writing blocks preserve the recognised lead',()=>{
 const lead='El estreno de la nueva temporada devuelve al personaje al centro de la conversación pública.';
 const raw='ESTADO_CAUSA: CONFIRMADA\n### **Explicación principal — apta para X (100 caracteres)**\n:::writing{variant="social_post"}\n'+lead+'\n:::\n\n## Qué sabemos\nOtro contexto.';
 assert.equal(editorial(raw),lead);
 assert.equal(publishableText(tweetText(raw,{rank:8,name:'Antonio Recio'})),true);
 assert.doesNotMatch(explanationText(raw,{rank:8,name:'Antonio Recio'}),/:::|\*\*|Qué sabemos/);
});
test('empty capture stays pending and publication actions cannot send parser notices',()=>{
 assert.equal(explanationText('',{}),'Explicación pendiente.');
 assert.equal(publishableText(tweetText('',{})),false);
 assert.match(app,/x\.disabled=!publishableText\(text\)/);
 assert.match(app,/withImage\.disabled=!publishableText\(text\)/);
 assert.match(app,/item.status==="explicada"\?explanationText\(item.explanation,item\)/);
});
