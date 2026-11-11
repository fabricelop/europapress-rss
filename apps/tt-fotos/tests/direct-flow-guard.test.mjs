import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const dir=path.dirname(fileURLToPath(import.meta.url));
const file=fs.readFileSync(path.resolve(dir,'../../../.github/workflows/tt-fotos-standalone-deploy.yml'),'utf8');
test('legacy standalone photo storage deployment is disabled and has no automatic push trigger',()=>{
 assert.match(file,/jobs:\s*\n\s*deploy:\s*\n(?:[^\n]*\n)*?\s*if:\s*\$\{\{ false \}\}/);
 assert(!/^\s+push:/m.test(file),'No push deployment');
 assert.match(file,/workflow_dispatch:/);
});
test('direct-to-editorial requirement prohibits new R2/KV gallery as an intermediate',()=>{
 const doc=fs.readFileSync(path.resolve(dir,'../DIRECTO-A-FICHAS-SIN-ALMACEN.md'),'utf8');
 for(const k of ['ChatGPT Imágenes','commandId','editorialId','revision','sin almacén','bandeja'])assert.match(doc,new RegExp(k,'i'));
});
