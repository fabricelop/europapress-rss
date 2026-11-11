import test from 'node:test';
import assert from 'node:assert/strict';
import {searchEditorial,resolveEditorialCommand} from '../src/editorial-search.mjs';
const fixture={
 'main/ttittulares/prepared.json':{items:[{event_id:'123456789abc',revision:1,title:'La situación económica en España'}]},
 'main/trends/site-top30-current.json':{items:[{editorial_id:'abcdef123456',revision:0,name:'Samantha Hudson'}]},
 'control/ttendencias-run-trigger/trends/image-runs/jobs/abcdef123456.json':{
   command_id:'tr-img-auto-abcdef123456-r0-a1-1794402335209',target_id:'abcdef123456',revision:0,project:'ttendencias',target_name:'Samantha Hudson'
 }
};
const fetcher=async url=>{
 const key=String(url).replace('https://raw.githubusercontent.com/fabricelop/europapress-rss/','');
 return new Response(JSON.stringify(fixture[key]||{}),{status:fixture[key]?200:404});
};
test('search by Spanish accents, title and trend name',async()=>{
 assert.equal((await searchEditorial('economica',fetcher))[0].editorialId,'123456789abc');
 assert.equal((await searchEditorial('samantha',fetcher))[0].project,'ttendencias');
 assert.equal((await searchEditorial('xyz absent',fetcher)).length,0);
});
test('only exact matching job revision can be used for manual association',async()=>{
 const good=await resolveEditorialCommand({project:'ttendencias',editorialId:'abcdef123456',revision:0},fetcher);
 assert.equal(good.commandId,'tr-img-auto-abcdef123456-r0-a1-1794402335209');
 assert.equal(await resolveEditorialCommand({project:'ttendencias',editorialId:'abcdef123456',revision:1},fetcher),null);
 assert.equal(await resolveEditorialCommand({project:'ttendencias',editorialId:'../../bad',revision:0},fetcher),null);
});