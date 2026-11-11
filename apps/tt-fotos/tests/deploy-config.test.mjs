import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const base=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
test('deploy config template contains no passwords or editor email',()=>{
 const t=fs.readFileSync(path.join(base,'wrangler.jsonc.example'),'utf8');
 assert(!/TT_FOTOS_ALLOWED_EMAIL|CLOUDFLARE_API_TOKEN|SECRET_ACCESS_KEY/.test(t));
 const config=JSON.parse(t);
 assert.equal(config.name,'tt-fotos-independent');
});
test('worker binding is separate from iPhone and legacy TTActualidad Site',()=>{
 const source=fs.readFileSync(path.join(base,'src/worker.mjs'),'utf8');
 assert(!/https:\/\/ttactualidad\.rainyraven22\.chatgpt\.site/.test(source));
 assert(!/image-inbox\/v1/.test(source));
});