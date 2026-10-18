import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('docs/ttactualidad/index.html','utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert(script,'Missing TTActualidad script');
const begin=script.indexOf('function emergencyGithubIssueUrl(');
const end=script.indexOf('async function pilotSend(',begin);
assert(begin>=0&&end>begin,'Direct issue API action is missing');
const part=script.slice(begin,end);
const token='github_pat_'+'a'.repeat(65);
const store=new Map(),pendingDeletes=new Map(),calls=[],toasts=[];
const elements={
 'emergency-token':{value:token,focus(){}},
 'emergency-settings':{open:false},
 'emergency-connect':{disabled:false,textContent:''},
 'emergency-auth-status':{textContent:''},
 'emergency-error':{textContent:''}
};
const sandbox={
 URL,URLSearchParams,AbortSignal,crypto,Date,Number,sessionStorage:{
  getItem:k=>store.get(k)||null,setItem:(k,v)=>store.set(k,v),removeItem:k=>store.delete(k)},
 pendingDeletes,removeKey:(p,id)=>p+':'+id,
 itemProject:item=>item._kind==='tr'?'ttendencias':'ttittulares',
 $:id=>elements[id],savePending(){},render(){},schedulePendingChecks(){},checkPendingDeletes(){},
 showToast:m=>toasts.push(m),
 fetch:async(url,options)=>{
  calls.push({url,options});
  if(url==='https://api.github.com/user')return {ok:true,status:200,json:async()=>({login:'fabricelop'})};
  if(url==='https://api.github.com/repos/fabricelop/europapress-rss/issues')
   return {status:201,json:async()=>({number:123})};
  throw Error('Unexpected API request '+url);
 },
 console
};
vm.runInNewContext(part+`\n
globalThis.API_TEST={emergencyPair,sendEmergencyDirect,emergencyForget,emergencySessionToken}
`,sandbox,{timeout:1000});
const api=sandbox.API_TEST;
const item={_kind:'tti',_id:'abc123',title:'Título público',revision:1};
await api.sendEmergencyDirect(item,'deleted');
assert.equal(calls.length,0,'No API call should be made without a token');
assert.equal(elements['emergency-settings'].open,true,'Pairing should stay inside the app');
await api.emergencyPair();
assert.equal(calls[0].url,'https://api.github.com/user','Must validate owner first');
assert.equal(store.size,1,'Session-only token');
await new Promise(resolve=>setTimeout(resolve,0));
assert.equal(calls.length,2,'After owner verification, submit pending action directly');
assert.equal(calls[1].url,'https://api.github.com/repos/fabricelop/europapress-rss/issues');
assert.equal(calls[1].options.method,'POST');
assert.equal(calls[1].options.headers['Authorization'],'Bearer '+token);
const body=JSON.parse(calls[1].options.body);
assert(body.title.startsWith('[TT-MOVIL] ttittulares deleted abc123'));
assert(body.body.includes('### Acción\n\ndeleted'));
assert.equal(pendingDeletes.get('ttittulares:abc123')?.issue_number,123);
assert.equal(pendingDeletes.get('ttittulares:abc123')?.status,'awaiting_github');
await api.sendEmergencyDirect(item,'deleted');
assert.equal(calls.length,2,'Prevent duplicate issue while awaiting GitHub');
assert(!html.includes('location.href=url;'),'Old redirect flow must be removed');
api.emergencyForget();
assert.equal(store.size,0,'Disconnect removes the token');
console.log('TT_EMERGENCY_ONE_TAP_API_OK: owner verified, POST, duplicate guard, session-only secret, no redirect');
