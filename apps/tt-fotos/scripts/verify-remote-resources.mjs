// Non-destructive remote resource verification before ANY schema migration.
// The Wrangler account must already be selected by CLOUDFLARE_ACCOUNT_ID.
// Do not create or modify resources here.
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const DATABASE_NAME='tt-fotos-private';
const BUCKET_NAME='tt-fotos-originals-private';
const UUID=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
export function verifyRemoteBindings(d1List,r2Info,databaseId) {
 if(!UUID.test(String(databaseId||'')))throw Error('TT_FOTOS_D1_ID_INVALID');
 const dbs=Array.isArray(d1List)?d1List:(Array.isArray(d1List?.databases)?d1List.databases:null);
 if(!dbs)throw Error('CLOUDFLARE_D1_LIST_UNEXPECTED');
 const matches=dbs.filter(x=>x?.name===DATABASE_NAME);
 if(matches.length!==1)throw Error('TT_FOTOS_PRIVATE_D1_NOT_FOUND_OR_AMBIGUOUS');
 const actual=String(matches[0].uuid||matches[0].id||'');
 if(actual.toLowerCase()!==databaseId.toLowerCase())throw Error('TT_FOTOS_PRIVATE_D1_UUID_MISMATCH');
 const bucket=r2Info?.name||r2Info?.bucket?.name;
 if(bucket!==BUCKET_NAME)throw Error('TT_FOTOS_PRIVATE_R2_NOT_FOUND_OR_WRONG_BUCKET');
 return {database:DATABASE_NAME,bucket:BUCKET_NAME,validated:true};
}
function runJsonCommand(...args){
 const cli=process.platform==='win32'?'npx.cmd':'npx';
 const output=execFileSync(cli,['wrangler',...args],{
  encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:30000,maxBuffer:8*1024*1024
 });
 return JSON.parse(output);
}
export function verifyFromCloudflare() {
 const databaseId=process.env.TT_FOTOS_D1_DATABASE_ID;
 if(!UUID.test(String(databaseId||'')))throw Error('TT_FOTOS_D1_ID_INVALID');
 if(!/^[a-f0-9]{32}$/i.test(String(process.env.CLOUDFLARE_ACCOUNT_ID||'')))throw Error('CLOUDFLARE_ACCOUNT_ID_REQUIRED');
 const databases=runJsonCommand('d1','list','--json');
 const bucket=runJsonCommand('r2','bucket','info',BUCKET_NAME,'--json');
 const result=verifyRemoteBindings(databases,bucket,databaseId);
 console.log('TT_FOTOS_REMOTE_RESOURCES_VERIFIED D1='+result.database+' R2='+result.bucket+' scope=read_only');
 return result;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{verifyFromCloudflare()}catch(e){
  console.error('TT_FOTOS_PREFLIGHT_BLOCKED '+String(e?.message||e));
  process.exitCode=1;
 }
}
