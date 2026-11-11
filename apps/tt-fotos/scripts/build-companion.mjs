// Build an unpacked Chrome companion restricted to one exact TT Fotos origin.
// Only the extension's source code is stored on disk; photos move in memory.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const dir=path.dirname(fileURLToPath(import.meta.url));
const sourceDir=path.resolve(dir,'../extension-templates');
const output=path.resolve(dir,'../dist/chrome-companion');
const raw=process.argv[2]||'';
let destination;
try{
 const u=new URL(raw);
 if(u.protocol!=='https:'||!u.hostname||u.pathname!=='/'||u.search||u.hash||u.username||u.password)throw Error();
 destination=u.origin;
}catch{console.error('Usage: node scripts/build-companion.mjs https://EXACT-TT-FOTOS-ORIGIN');process.exit(2)}
if(destination.includes('ttactualidad.rainyraven22.chatgpt.site'))throw Error('OLD_SITE_NOT_ALLOWED');
fs.mkdirSync(output,{recursive:true});
for(const name of ['manifest.json','background.js','images-source.js','site-receiver.js']){
 let content=fs.readFileSync(path.join(sourceDir,name),'utf8');
 if(name==='manifest.json'){
   const manifest=JSON.parse(content);
   manifest.name='TT Fotos independiente — vincular ChatGPT Imágenes';
   manifest.description='Transfiere fotografías visibles desde ChatGPT a un Worker TT Fotos privado; no modifica TTActualidad ni iPhone.';
   manifest.host_permissions=['https://chatgpt.com/*',destination+'/*'];
   manifest.content_scripts=manifest.content_scripts.map(script=>script.matches.includes('__TT_FOTOS_ORIGIN__/*')?{...script,matches:[destination+'/*']}:script);
   content=JSON.stringify(manifest,null,2).replaceAll('__TT_FOTOS_ORIGIN__',destination)+'\n';
 } else if(name==='background.js'){
   const before="const DEST='__TT_FOTOS_ORIGIN__';";
   if(!content.includes(before))throw Error('SOURCE_COMPANION_CHANGED');
   content=content.replace(before,`const DEST=${JSON.stringify(destination)};`);
 }
 fs.writeFileSync(path.join(output,name),content,{flag:'w',mode:0o600});
}
console.log('TT_FOTOS_COMPANION_BUILT '+destination+' files=4');