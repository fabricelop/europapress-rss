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
if(!/^[a-f0-9-]{32,36}$/i.test(id))throw Error('D1_DATABASE_ID_INVALID');
const template=JSON.parse(fs.readFileSync(path.join(root,'wrangler.jsonc.example'),'utf8'));
template.d1_databases[0].database_id=id;
template.vars.CF_ACCESS_ISSUER=issuer.origin;
template.vars.CF_ACCESS_AUD=process.env.TT_FOTOS_ACCESS_AUD;
fs.writeFileSync(path.join(root,'wrangler.jsonc'),JSON.stringify(template,null,2)+'\n',{mode:0o600});
console.log('TT_FOTOS_WRANGLER_READY independently_configured=true');