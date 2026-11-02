'use strict';
// Static UI contract: the badge must indicate VERIFIED materialized imagery,
// not a launched generation or an unverified archive photograph.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const p=require('node:path');
for(const file of ['pilot/ttactualidad-live/index.html','docs/ttactualidad/index.html']){
 test(file+' shows one small IA marker only when verifiedNewsAI or verifiedTrendSiteAI returns a URL',()=>{
  const src=fs.readFileSync(p.join(__dirname,'..',file),'utf8');
  assert.match(src,/function verifiedNewsAI\(x\)/);
  assert.match(src,/function verifiedTrendSiteAI\(x\)/);
  assert.match(src,/const newsAI=verifiedNewsAI\(x\)/);
  assert.match(src,/const trendSiteAI=verifiedTrendSiteAI\(x\)/);
  assert.match(src,/\(newsAI\|\|trendSiteAI\?'<span class="ai-image-marker"/);
  assert.match(src,/aria-label="Imagen IA asociada"/);
  assert.match(src,/\.meta \.ai-image-marker\{[^}]*font-size:10px/);
  assert.ok(!src.includes('ai_image_status===\'ready\'?\'<span class="ai-image-marker"'));
 });
}
