'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'tt-web-image-test-'));
try{
 fs.copyFileSync(path.join(__dirname,'../TTendenciasWebImages.cjs'),path.join(root,'exporter.cjs'));
 const {enroll}=require(path.join(root,'exporter.cjs'));
 const secret='test-only-'+require('node:crypto').randomBytes(32).toString('hex');
 const input={startPublisher:false,job:{command_id:'cmd-test',target_id:'tt-test',revision:1,context_snapshot:{explanation:'Texto de prueba'}},commandId:'cmd-test',targetId:'tt-test',conversationUrl:'https://chatgpt.com/c/abc-123',secret};
 enroll(input);
 const file=path.join(root,'ttendencias-web-images/cmd-test.json'),text=fs.readFileSync(file,'utf8'),row=JSON.parse(text);
 assert.ok(!text.includes(secret));assert.ok(row.secret_dpapi);assert.equal(row.revision,1);
 const decoded=execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command','$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}'],{input:row.secret_dpapi,encoding:'utf8'});
 assert.equal(decoded,secret);
 enroll({...input,secret:'different-secret-that-must-not-overwrite-command'});assert.equal(fs.readFileSync(file,'utf8'),text);
 console.log('PASS DPAPI: encrypted secret, successful recovery, immutable enrollment');
}finally{fs.rmSync(root,{recursive:true,force:true});}
