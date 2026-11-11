import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const valid={
 TT_FOTOS_D1_DATABASE_ID:'11111111-2222-3333-4444-555555555555',
 TT_FOTOS_ACCESS_ISSUER:'https://editor-team.cloudflareaccess.com',
 TT_FOTOS_ACCESS_AUD:'a'.repeat(64),
 TT_FOTOS_ALLOWED_EMAIL:'editor@example.org, second@example.org',
 CLOUDFLARE_ACCOUNT_ID:'b'.repeat(32)
};
function workspace(run){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tt-fotos-preflight-'));
 try{
  fs.mkdirSync(path.join(dir,'scripts'));
  fs.copyFileSync(path.join(source,'scripts/prepare-deploy.mjs'),path.join(dir,'scripts/prepare-deploy.mjs'));
  fs.copyFileSync(path.join(source,'wrangler.jsonc.example'),path.join(dir,'wrangler.jsonc.example'));
  return run(dir,env=>execFileSync(process.execPath,[path.join(dir,'scripts/prepare-deploy.mjs')],{
    env:{...process.env,...valid,...env},cwd:dir,encoding:'utf8',stdio:'pipe'
  }));
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
}
test('validated Cloudflare configuration only targets dedicated TT Fotos resources',()=>workspace((dir,run)=>{
 const log=run({});
 assert.match(log,/independently_configured=true/);
 const c=JSON.parse(fs.readFileSync(path.join(dir,'wrangler.jsonc'),'utf8'));
 assert.equal(c.name,'tt-fotos-independent');
 assert.equal(c.d1_databases[0].database_name,'tt-fotos-private');
 assert.equal(c.r2_buckets[0].bucket_name,'tt-fotos-originals-private');
 assert.equal(c.vars.CF_ACCESS_AUD,valid.TT_FOTOS_ACCESS_AUD);
 assert.equal(c.vars.CF_ACCESS_ISSUER,valid.TT_FOTOS_ACCESS_ISSUER);
 assert.equal(JSON.stringify(c).includes('editor@example.org'),false);
}));
test('invalid account, D1 UUID, Access AUD, issuer and email list stop before writing',()=>workspace((dir,run)=>{
 const cases=[
 {CLOUDFLARE_ACCOUNT_ID:'wrong'},
 {TT_FOTOS_D1_DATABASE_ID:'11111111-not-a-real-db'},
 {TT_FOTOS_ACCESS_AUD:'not-an-app-audience'},
 {TT_FOTOS_ACCESS_ISSUER:'http://editor-team.cloudflareaccess.com'},
 {TT_FOTOS_ALLOWED_EMAIL:'*'},
 {TT_FOTOS_ALLOWED_EMAIL:'not-an-email'}
 ];
 for(const c of cases){
  assert.throws(()=>run(c));
  assert.equal(fs.existsSync(path.join(dir,'wrangler.jsonc')),false);
 }
}));
test('template drift fails closed before generating Wrangler deployment file',()=>workspace((dir,run)=>{
 const file=path.join(dir,'wrangler.jsonc.example');
 const template=JSON.parse(fs.readFileSync(file,'utf8'));
 template.name='existing-production-worker';
 fs.writeFileSync(file,JSON.stringify(template));
 assert.throws(()=>run({}));
 assert.equal(fs.existsSync(path.join(dir,'wrangler.jsonc')),false);
}));
