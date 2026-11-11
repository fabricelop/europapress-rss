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


test('no manual D1/R2 bootstrap can run after the direct-flow decision',()=>{
 const root=path.resolve(dir,'../../../.github/workflows');
 for(const name of ['tt-fotos-standalone-deploy.yml','tt-fotos-prepare-storage.yml']){
  const workflow=fs.readFileSync(path.join(root,name),'utf8');
  assert.match(workflow,/jobs:\s*\n\s*(?:deploy|prepare):\s*\n(?:[^\n]*\n)*?\s*if:\s*\$\{\{\s*false\s*\}\}/,
   name+' must not provision duplicate D1/R2 on dispatch');
  assert.doesNotMatch(workflow,/^\s+push:/m,name+' must remain manual only');
 }
 const readme=fs.readFileSync(path.resolve(dir,'../README.md'),'utf8');
 assert.match(readme,/ARQUITECTURA LEGADA — NO DESPLEGAR/);
});
