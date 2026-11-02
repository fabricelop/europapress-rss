const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..');
function source(file){return fs.readFileSync(path.join(root,file),'utf8')}
function fn(file,start,end,name){const s=source(file);return vm.runInNewContext(s.slice(s.indexOf(start),s.indexOf(end,s.indexOf(start)))+'\n'+name,{commandId:'test-command',targetId:'test-target'})}
test('both publishers reject automatic association before reading state or uploading bytes',async()=>{
 for(const file of ['TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs']){
  const consume=fn(file,'async function consume(task){','async function telemetry(', 'consume');
  assert.deepEqual(JSON.parse(JSON.stringify(await consume({target_id:'id',upload_accepted_at:'old',status:'published'}))),{status:'waiting',reason:'manual_approval_required'});
 }
});
test('trend generator preserves image request and factual context, and never requests automatic attachment',()=>{
 const build=fn('TTendenciasImageBridge.js','function buildMessage(job){','const BRIDGE_MODE=', 'buildMessage');
 for(const mode of ['humor','rigor']){
  const out=build({target_name:'Tema',revision:3,editorial_image_mode:mode,context_snapshot:{explanation:'HECHO EXACTO',explained_at:'2026-11-02T12:00:00Z',image_style:'ESTILO EXACTO'}});
  assert.match(out,/TTENDENCIAS_IMAGE_JOB_V4 test-command test-target/);assert.match(out,/HECHO EXACTO/);assert.match(out,/ESTILO EXACTO/);assert.match(out,/APROBACIÓN MANUAL OBLIGATORIA/);assert.doesNotMatch(out,/TTENDENCIAS_SITE_AUTO_RECEIPT|attach_trend_image|Sincroniza automáticamente/);
 }
});
test('direct bridge upload is blocked independently in both projects',async()=>{
 for(const file of ['TTendenciasImageBridge.js','TTiTTularesImageBridge.js']){
  const s=source(file),start=s.indexOf('async function uploadImage(image){'),end=s.indexOf('\nasync function ',start+5);
  const upload=vm.runInNewContext(s.slice(start,end)+'\nuploadImage');await assert.rejects(()=>upload({dataUrl:'original'}),/manual_approval_required/);
 }
});
