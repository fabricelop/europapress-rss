'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const source=fs.readFileSync('windows/TTendenciasImageBridge.js','utf8');
const start=source.indexOf('function buildMessage(job){'),end=source.indexOf('\nconst BRIDGE_MODE=',start);
const command='tr-img-auto-trend-test-r2-a1-1234567890',target='trend-test';
const build=new Function('commandId','targetId',source.slice(start,end)+';return buildMessage;')(command,target);
const context={explanation:'TT#17 Álex & Marc.\n#MotoGP\n🌶️ Texto exacto.',explained_at:'2026-10-31T11:16:00Z',image_style:'Estilo asignado exacto',image_style_name:'test-style',closer_text:'🌶️ Texto exacto.'};
for(const mode of ['humor','rigor'])test(mode+': create once first, then return the same original through Sites with exact episode identity',()=>{
 const prompt=build({revision:2,target_name:'Álex & Marc',editorial_image_mode:mode,context_snapshot:context});
 assert.ok(prompt.startsWith('TTENDENCIAS_IMAGE_JOB_V4 '+command+' '+target));
 assert.ok(prompt.includes(context.explanation));assert.ok(prompt.includes(context.image_style));
 assert.ok(prompt.includes('[@Sites](plugin://sites@openai-curated-remote)'));
 assert.ok(prompt.includes('scripts/attach-image.mjs'));
 assert.ok(prompt.includes('no autoriza repetir la generación'));
 const marker='CONTEXTO DE ASOCIACIÓN EXACTO (NO VISIBLE EN LA ILUSTRACIÓN): ';
 const pos=prompt.indexOf(marker)+marker.length;
 // JSON contains escaped explanation newlines; parse the complete first line
 // by finding its closing brace, independent of the legacy rigor separator.
 const encoded=prompt.slice(pos,prompt.indexOf('}',pos)+1);
 const identity=JSON.parse(encoded);
 assert.equal(identity.target_id,target);assert.equal(identity.revision,2);
 assert.equal(identity.project_id,'appgprj_6ae4dcf7d7488191a574e5b649e67370');
 assert.equal(identity.explanation,context.explanation);assert.equal(identity.explained_at,context.explained_at);
 assert.ok(prompt.indexOf('genera UNA')<prompt.indexOf('PASO POSTERIOR OBLIGATORIO'));
 assert.ok(!prompt.includes('ni persistas la imagen'));
 if(mode==='rigor')assert.ok(prompt.includes('No hagas humor ni sátira'));
});
