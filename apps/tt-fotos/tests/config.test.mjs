import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
test('example configuration serves all static assets behind authenticated Worker',()=>{
 const config=JSON.parse(fs.readFileSync(path.join(root,'wrangler.jsonc.example'),'utf8'));
 assert.equal(config.assets.run_worker_first,true);
 assert.equal(config.assets.binding,'ASSETS');
 assert.equal(config.main,'src/worker.mjs');
 assert.equal(config.r2_buckets[0].binding,'FOTOS_R2');
 assert.equal(config.d1_databases[0].binding,'FOTOS_DB');
});
test('the standalone source does not call old Site or iPhone endpoints',()=>{
 const file=fs.readFileSync(path.join(root,'src/worker.mjs'),'utf8');
 assert(!file.includes('ttactualidad.rainyraven22.chatgpt.site'));
 assert(!file.includes('image-inbox'));
 assert(!file.includes('X-TT-Ingest-Key'));
});