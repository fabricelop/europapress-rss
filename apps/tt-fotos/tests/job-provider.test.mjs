import test from 'node:test';
import assert from 'node:assert/strict';
import {createGithubJobProvider} from '../src/lib/job-provider.mjs';
import {lookupEditorialIdentity} from '../src/lib/editorial-registry.mjs';

const cmdNews='tt-img-auto-683beffb5aed-r1-a1-1794423415726';
const cmdTrend='tr-img-auto-e617da285349-r0-a1-1794421194128';
const root='https://raw.githubusercontent.com/fabricelop/europapress-rss/';
const canonical={
 'main/ttittulares/prepared.json':{items:[{event_id:'c2c5fea57972',revision:1,title:'Una noticia preparada'}]},
 'main/ttittulares/status.json':{events:{'683beffb5aed':{title:'De la Fuente y Lamine Yamal',revision:1,status:'ELIGIBLE'}}},
 'main/trends/site-top30-current.json':{items:[{editorial_id:'e617da285349',revision:0,name:'Samantha Hudson'}]}
};
function fakeFetcher(extra={},errorStatus=404){
 const fixture={...canonical,...extra};
 return async url=>{
  const key=String(url).replace(root,'');
  return key in fixture?new Response(JSON.stringify(fixture[key]),{status:200}):new Response('missing',{status:errorStatus});
 };
}
test('news with no upstream image receipt is corroborated by exact ID and revision in radar',async()=>{
 const j=await createGithubJobProvider(fakeFetcher()).find(cmdNews);
 assert.equal(j.command_id,cmdNews);
 assert.equal(j.project,'ttittulares');
 assert.equal(j.target_name,'De la Fuente y Lamine Yamal');
 assert.equal(j.verification,'editorial_identity_only');
 assert.equal(j.editorial_source,'ttittulares/status.json');
});
test('trend with no upstream image receipt is corroborated by exact ID and revision in current Top 30',async()=>{
 const j=await createGithubJobProvider(fakeFetcher()).find(cmdTrend);
 assert.equal(j.target_name,'Samantha Hudson');
 assert.equal(j.verification,'editorial_identity_only');
 assert.equal(j.revision,0);
});
test('missing, malformed, changed revision and untrusted paths do not produce a job',async()=>{
 const p=createGithubJobProvider(fakeFetcher());
 assert.equal(await p.find('tt-img-auto-683beffb5aed-r2-a1-1794423415726'),null);
 assert.equal(await p.find('tr-img-auto-e617da285349-r1-a1-1794421194128'),null);
 assert.equal(await p.find('tt-img-auto-aaaaaaaaaaaa-r1-a1-1794423415726'),null);
 assert.equal(await p.find('../../bad'),null);
 assert.equal(await lookupEditorialIdentity({project:'ttittulares',editorialId:'683beffb5aed',revision:-1},fakeFetcher()),null);
});
test('exact upstream receipt always wins over fallback',async()=>{
 const path='control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/683beffb5aed.json';
 const exact={command_id:cmdNews,target_id:'683beffb5aed',revision:1,project:'ttittulares',target_name:'Original signed job'};
 const j=await createGithubJobProvider(fakeFetcher({[path]:exact})).find(cmdNews);
 assert.equal(j.verification,'exact_job');
 assert.equal(j.target_name,'Original signed job');
});
test('conflicting upstream receipt and upstream 5xx fail closed, no weak fallback',async()=>{
 const path='control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/683beffb5aed.json';
 const conflict={command_id:cmdTrend,target_id:'683beffb5aed',revision:1,project:'ttittulares'};
 assert.equal(await createGithubJobProvider(fakeFetcher({[path]:conflict})).find(cmdNews),null);
 assert.equal(await createGithubJobProvider(fakeFetcher({},503)).find(cmdNews),null);
});
