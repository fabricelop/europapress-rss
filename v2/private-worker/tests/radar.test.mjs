import test from "node:test";
import assert from "node:assert/strict";
import {captureRadar,loadRadar,mergeEditorialRadar,parseGetDayTrends,radarAgeMinutes} from "../src/radar.js";
import worker from "../src/index.js";

function html(names){
 const first=names.slice(0,15).map((name,i)=>`<tr><td>${i+1}</td><td><a href="/es/?q=x">${name}</a></td></tr>`).join("");
 const second=names.slice(15).map((name,i)=>`<tr><td>${i+16}</td><td><a>${name}</a></td></tr>`).join("");
 return '<html><title>España</title>'+(' '.repeat(1600))+'<table class="ranking trends"><tbody>'+first+'</tbody></table><table class="ranking trends">'+second+'</table></html>';
}
const names=Array.from({length:30},(_,i)=>"Trend "+(i+1));
function database(){
 let raw=null;
 return {
   prepare(query){
     let params=[];
     return {
       bind(...args){params=args;return this},
       async first(){assert.match(query,/SELECT payload FROM v2_radar/);return raw?{payload:raw}:null},
       async run(){assert.match(query,/INSERT INTO v2_radar/);raw=params[0];return {success:true}}
     };
   }
 };
}
const fetcher=html=>async()=>new Response(html,{status:200,headers:{date:"Sat, 14 Nov 2026 21:00:00 GMT"}});
const time=x=>new Date("2026-11-14T"+x+":00.000Z");
const bare={project:"ttactualidad-v2",country:"ES",count:30,items:names.map((name,i)=>({
 name,rank:i+1,trend_id:"trv2-"+String(i+1).padStart(24,"0"),status:"explicada",status_label:"Explicada",
 explanation:"Explicación de "+name,entered_top30_at:"2026-11-13T16:00:00Z"
}))};

test("GetDayTrends parser chooses two ranking tables, never daily hashtags",()=>{
 const actual=parseGetDayTrends(html(names)+"<table class='ranking hashtags'><tr><td>1</td><td>FALSE</td></tr></table>");
 assert.deepEqual(actual,names);
 assert.throws(()=>parseGetDayTrends(html(names.slice(0,29))),/INCOMPLETE/);
 assert.throws(()=>parseGetDayTrends("<html>Unrelated ranking</html>"),/MARKUP/);
});

test("Cloudflare cron stores exactly one snapshot and calculates adjacent ranks",async()=>{
 const db=database();
 const first=await captureRadar(db,{fetcher:fetcher(html(names)),now:time("21:00")});
 assert.equal(first.names.length,30);
 assert.equal(first.previous_capture_at,null);
 const second=await captureRadar(db,{fetcher:fetcher(html(names)),now:time("21:15")});
 assert.equal(second.identical_captures,2);
 assert.equal(second.unchanged_since,first.captured_at);
 assert.equal(second.previous_ranks["trend 1"],null);
 assert.equal(second.movement_kinds["trend 1"],"baseline");
 const changed=names.slice();
 [changed[0],changed[4]]=[changed[4],changed[0]];
 const third=await captureRadar(db,{fetcher:fetcher(html(changed)),now:time("21:30")});
 assert.equal(third.previous_ranks["trend 5"],5);
 assert.equal(third.previous_ranks["trend 1"],1);
 assert.equal(third.identical_captures,1);
 assert.equal((await loadRadar(db)).captured_at,third.captured_at);
 const merged=await mergeEditorialRadar(bare,third,time("21:35").getTime());
 assert.equal(merged.items[0].name,"Trend 5");
 assert.equal(merged.items[0].positions_changed,4);
 assert.equal(merged.items[4].positions_changed,-4);
 assert.equal(merged.items[1].positions_changed,null);
 assert.equal(merged.items[0].explanation,"Explicación de Trend 5");
 assert.equal(merged.radar_source,"cloudflare_cron_15m");
});

test("Each trend keeps its last real movement through later partial and identical changes",async()=>{
 const db=database();
 await captureRadar(db,{fetcher:fetcher(html(names)),now:time("21:00")});
 const moved=names.slice();
 [moved[0],moved[4]]=[moved[4],moved[0]];
 await captureRadar(db,{fetcher:fetcher(html(moved)),now:time("21:15")});
 const partial=moved.slice();
 [partial[1],partial[2]]=[partial[2],partial[1]];
 const third=await captureRadar(db,{fetcher:fetcher(html(partial)),now:time("21:30")});
 assert.equal(third.previous_ranks["trend 5"],5);
 assert.equal(third.movement_kinds["trend 5"],"up");
 assert.equal(third.previous_ranks["trend 2"],2);
 const fourth=await captureRadar(db,{fetcher:fetcher(html(partial)),now:time("21:45")});
 const merged=await mergeEditorialRadar(bare,fourth,time("21:46").getTime());
 assert.equal(merged.ranking_unchanged,true);
 assert.equal(merged.ranking_change_at,third.captured_at);
 assert.equal(merged.items[0].positions_changed,4);
 assert.equal(merged.items[2].positions_changed,-1);
 assert.equal(merged.items[5].positions_changed,null);
});

test("Unchanged third-party ranking is flagged but not silently called live X",async()=>{
 const db=database();
 for(const stamp of ["20:00","20:15","20:30","20:45"]){
   await captureRadar(db,{fetcher:fetcher(html(names)),now:time(stamp)});
 }
 const last=await loadRadar(db);
 const merged=await mergeEditorialRadar(bare,last,time("20:46").getTime());
 assert.equal(merged.radar_identical_captures,4);
 assert.match(merged.radar_warning,/fuente externa/);
 assert.equal(merged.radar_source_verified_against_x,false);
 const old=await mergeEditorialRadar(bare,last,time("22:00").getTime());
 assert.equal(old.radar_source,"cloudflare_stale_fallback");
 assert.ok(radarAgeMinutes(last,time("22:00").getTime())>45);
});

test("New trend without editorial entry stays pending and has stable identity",async()=>{
 const db=database();
 await captureRadar(db,{fetcher:fetcher(html(names)),now:time("21:00")});
 const next=["Nuevo tema",...names.slice(0,29)];
 const captured=await captureRadar(db,{fetcher:fetcher(html(next)),now:time("21:15")});
 const doc=await mergeEditorialRadar(bare,captured,time("21:16").getTime());
 assert.equal(doc.items[0].name,"Nuevo tema");
 assert.equal(doc.items[0].status,"pendiente");
 assert.equal(doc.items[0].previous_rank,null);
 assert.match(doc.items[0].trend_id,/^trv2-[a-f0-9]{24}$/);
 assert.equal(doc.items[1].positions_changed,-1);
});

test("Third party errors never update or erase the last known good snapshot",async()=>{
 const db=database();
 const good=await captureRadar(db,{fetcher:fetcher(html(names)),now:time("21:00")});
 await assert.rejects(()=>captureRadar(db,{fetcher:async()=>new Response("blocked",{status:403}),now:time("21:15")}),/HTTP_403/);
 assert.equal((await loadRadar(db)).captured_at,good.captured_at);
});

test("Cloudflare Worker exposes real scheduled handler",()=>{
 assert.equal(typeof worker.scheduled,"function");
});
