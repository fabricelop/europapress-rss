// Assemble Wrangler config from known environment values; never include editor secrets.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const needed=['TT_FOTOS_D1_DATABASE_ID','TT_FOTOS_ACCESS_ISSUER','TT_FOTOS_ACCESS_AUD'];
for(const key of needed){if(!process.env[key]||/PUT_|YOUR_/.test(process.env[key]))throw Error('MISSING_DEPLOY_SETTING: '+key)}
const issuer=new URL(process.env.TT_FOTOS_ACCESS_ISSUER);
if(issuer.protocol!=='https:'||!issuer.hostname.endsWith('.cloudflareaccess.com')||issuer.pathname!=='/')throw Error('ACCESS_ISSUER_INVALID');
const id=process.env.TT_FOTOS_D1_DATABASE_ID;
if(!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id))throw Error('D1_DATABASE_ID_INVALID');
if(!/^[a-f0-9]{64}$/i.test(process.env.TT_FOTOS_ACCESS_AUD))throw Error('ACCESS_AUD_INVALID');
if(process.env.CLOUDFLARE_ACCOUNT_ID&&!/^[a-f0-9]{32}$/i.test(process.env.CLOUDFLARE_ACCOUNT_ID))
 throw Error('CLOUDFLARE_ACCOUNT_ID_INVALID');
if(process.env.TT_FOTOS_ALLOWED_EMAIL!==undefined){
 const emails=process.env.TT_FOTOS_ALLOWED_EMAIL.split(',').map(x=>x.trim());
 if(!emails.length||emails.some(x=>!/^[^\\s@,]+@[^\\s@,.]+(?:\\.[^\\s@,.]+)+$/.test(x)))
  throw Error('EDITOR_ALLOWLIST_INVALID');
}
const template=JSON.parse(fs.readFileSync(path.join(root,'wrangler.jsonc.example'),'utf8'));
if(template.name!=='tt-fotos-independent'||template.d1_databases?.[0]?.database_name!=='tt-fotos-private'||
 template.r2_buckets?.[0]?.bucket_name!=='tt-fotos-originals-private'||
 template.assets?.run_worker_first!==true)throw Error('NOT_AN_ISOLATED_TT_FOTOS_TEMPLATE');
template.d1_databases[0].database_id=id;
template.vars.CF_ACCESS_ISSUER=issuer.origin;
template.vars.CF_ACCESS_AUD=process.env.TT_FOTOS_ACCESS_AUD;
const target=path.join(root,'wrangler.jsonc');
fs.writeFileSync(target,JSON.stringify(template,null,2)+'\n',{mode:0o600});
fs.chmodSync(target,0o600);
console.log('TT_FOTOS_WRANGLER_READY independently_configured=true');