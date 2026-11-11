import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const origin='https://tt-fotos-prueba.example.workers.dev';
test('browser connector is built only for exact standalone origin, with a visible editor popup',()=>{
 execFileSync(process.execPath,[path.join(root,'scripts/build-companion.mjs'),origin]);
 const target=path.join(root,'dist','chrome-companion');
 const manifest=JSON.parse(fs.readFileSync(path.join(target,'manifest.json'),'utf8'));
 assert.equal(manifest.action.default_popup,'popup.html');
 assert.deepEqual(manifest.host_permissions,['https://chatgpt.com/*',origin+'/*']);
 assert(manifest.content_scripts.some(script=>script.matches[0]===origin+'/*'));
 assert(!JSON.stringify(manifest).includes('ttactualidad.rainyraven22.chatgpt.site'));
 for(const filename of ['background.js','images-source.js','site-receiver.js','popup.js']){
  const file=path.join(target,filename);
  execFileSync(process.execPath,['--check',file]);
  assert(!fs.readFileSync(file,'utf8').includes('ttactualidad.rainyraven22.chatgpt.site'));
 }
 const ui=fs.readFileSync(path.join(target,'popup.html'),'utf8');
 assert.match(ui,/Detectadas/);assert.match(ui,/Guardadas/);
 assert.match(ui,/Sin asociar/);assert.match(ui,/Omitidas/);
 assert.match(ui,/a tamaño completo/);
});
test('connector cannot be bound to old TTActualidad Site or insecure HTTP',()=>{
 const script=path.join(root,'scripts/build-companion.mjs');
 assert.throws(()=>execFileSync(process.execPath,[script,'https://ttactualidad.rainyraven22.chatgpt.site'],{stdio:'pipe'}));
 assert.throws(()=>execFileSync(process.execPath,[script,'http://tt-fotos.example'],{stdio:'pipe'}));
 assert.throws(()=>execFileSync(process.execPath,[script,'https://tt-fotos.example/path'],{stdio:'pipe'}));
});
test('gallery origin sends photos only after an explicit editor click and reports skipped reasons',()=>{
 const popup=fs.readFileSync(path.join(root,'extension-templates/popup.js'),'utf8');
 const source=fs.readFileSync(path.join(root,'extension-templates/images-source.js'),'utf8');
 const background=fs.readFileSync(path.join(root,'extension-templates/background.js'),'utf8');
 assert.match(popup,/\$\('scan'\)\.onclick/);
 assert.match(source,/TT_FOTOS_PROGRESS/);
 assert.match(source,/visibleCandidates/);
 assert.match(source,/NOT_FULL_RESOLUTION/);
 assert(!background.includes('chrome.action.onClicked'));
 assert(!source.includes('chrome.tabs.create'));
});