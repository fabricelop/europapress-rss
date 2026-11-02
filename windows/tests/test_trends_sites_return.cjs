'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const source=fs.readFileSync('windows/TTendenciasImageBridge.js','utf8');
const start=source.indexOf('function buildMessage(job){'),end=source.indexOf('\nconst BRIDGE_MODE=',start);
assert.ok(start>=0&&end>start,'locate the exact automatic prompt builder');
const command='tr-img-auto-trend-test-r2-a1-1234567890',target='trend-test';
const build=new Function('commandId','targetId',source.slice(start,end)+';return buildMessage;')(command,target);
const context={explanation:'TT#17 Álex & Marc.\n#MotoGP\n🌶️ Texto exacto.',explained_at:'2026-10-31T11:16:00Z',image_style:'Estilo asignado exacto',image_style_name:'test-style',closer_text:'🌶️ Texto exacto.'};

for(const mode of ['humor','rigor'])test(mode+': preserves image generation and waits for approval without an automatic Site/App contract',()=>{
 const prompt=build({revision:2,target_name:'Álex & Marc',editorial_image_mode:mode,context_snapshot:context});
 assert.ok(prompt.startsWith('TTENDENCIAS_IMAGE_JOB_V4 '+command+' '+target));
 assert.ok(prompt.includes(context.explanation));assert.ok(prompt.includes(context.image_style));
 assert.match(prompt,/APROBACIÓN MANUAL OBLIGATORIA/);
 for(const automatic of ['TTENDENCIAS_SITE_AUTO_RECEIPT_V5','attach_trend_image','verify_trend_image','Sincroniza automáticamente'])assert.ok(!prompt.includes(automatic));
 if(mode==='rigor')assert.ok(prompt.includes('No hagas humor ni sátira'));
});
test('automatic Site-return follow-up is blocked before accessing ChatGPT or uploading an original',async()=>{
 const begin=source.indexOf('async function sendSiteReturnAfterImage(cdp,job){');
 const end=source.indexOf('\nasync function optionalWebHandoff(',begin);
 const send=new Function(source.slice(begin,end)+';return sendSiteReturnAfterImage;')();
 assert.equal(await send({},{}),'manual_approval_required');
});
