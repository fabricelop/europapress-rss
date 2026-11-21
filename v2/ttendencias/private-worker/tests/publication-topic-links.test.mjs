import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const base="https://v2-private.example.workers.dev";
const a="trv2-aaaaaaaaaaaaaaaaaaaaaaaa";
const b="trv2-bbbbbbbbbbbbbbbbbbbbbbbb";
const c="trv2-cccccccccccccccccccccccc";
const originals=[
 {trend_id:a,revision:1,name:"Alcaraz",status:"explicada",explanation:"Alcaraz remonta a Shelton en Turín y alcanza la final de las ATP Finals."},
 {trend_id:b,revision:1,name:"Shelton",status:"explicada",explanation:"Carlos Alcaraz supera a Shelton en semifinales de las ATP Finals de Turín."},
 {trend_id:c,revision:1,name:"Lorca",status:"explicada",explanation:"Lorca prepara el desfile medieval de San Clemente."}
];

test("PU persists only clear associations and permanently retires icons after Top30 exit",async()=>{
 let ranking=originals.slice();
 globalThis.fetch=async()=>Response.json({project:"ttactualidad-v2",count:ranking.length,items:ranking});
 const events=[],marks=new Map(),links=[];
 const db={async batch(statements){for(const s of statements)await s.run();return statements.map(()=>({success:true}));},
  prepare(sql){let args=[];return {bind(...values){args=values;return this;},
   async run(){
    if(sql.startsWith("INSERT INTO publication_clicks"))events.push({event_id:args[0],trend_id:args[1],revision:args[2],trend_name:args[3],pressed_at_ms:args[4]});
    if(sql.startsWith("INSERT INTO red_marks"))marks.set(args[0],args[1]);
    if(sql.startsWith("INSERT INTO trend_topic_links"))links.push({trend_id:args[0],revision:args[1],origin_trend_id:args[2],origin_revision:args[3],origin_name:args[4],invalidated_at_ms:null});
    if(sql.startsWith("UPDATE trend_topic_links")){
     for(const x of links)if(!x.invalidated_at_ms&&x.trend_id===args[1]&&x.revision===args[2]&&x.origin_trend_id===args[3]&&x.origin_revision===args[4])x.invalidated_at_ms=args[0];
    }
    return {success:true};
   },
   async all(){
    if(sql.includes("FROM publication_clicks"))return {results:events.filter(x=>x.pressed_at_ms>args[0]&&x.pressed_at_ms<=args[1])};
    if(sql.includes("FROM trend_topic_links"))return {results:links.filter(x=>!x.invalidated_at_ms)};
    throw Error("unknown query");
   },async first(){throw Error("radar not configured in test");}
  };}
 };
 const secret="test-password-with-enough-length";
 const env={MARKS_DB:db,AUTH_PASSWORD:secret,SESSION_SECRET:"very-long-session-signing-key-for-testing"};
 const login=await worker.fetch(new Request(base+"/api/login",{method:"POST",headers:{origin:base,"x-ttv2-action":"1"},body:JSON.stringify({password:secret})}),env);
 assert.equal(login.status,200);
 const cookie=login.headers.get("set-cookie").split(";")[0];
 const get=async()=>await (await worker.fetch(new Request(base+"/api/publication-count",{headers:{cookie}}),env)).json();
 const post=await worker.fetch(new Request(base+"/api/publication-count",{method:"POST",headers:{cookie,origin:base,"x-ttv2-action":"1"},body:JSON.stringify({event_id:crypto.randomUUID(),trend_id:a,revision:1})}),env);
 assert.equal(post.status,200);
 assert.equal(marks.has(a),true);
 const published=await post.json();
 assert.deepEqual(published.links.map(x=>x.trend_id),[b]);
 assert.equal(published.links[0].origin_name,"Alcaraz");
 assert.equal((await get()).links.length,1);
 ranking=[originals[0],originals[2]];
 assert.deepEqual((await get()).links,[]);
 ranking=originals.slice();
 assert.deepEqual((await get()).links,[],"a returning trend does not revive an expired association");
});
