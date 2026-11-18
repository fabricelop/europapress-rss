import test from "node:test";
import assert from "node:assert/strict";
import {dedupeNewsRows} from "../src/news-dedupe.js";

const date="2026-11-18T13:31:50Z";
function row(id,title,group="incident",time=date){
 return {event_id:"ttn2-"+id.repeat(24),revision:1,title,group,first_seen_at:time};
}
const pattinson="El actor británico Robert Pattinson será el próximo James Bond";
test("V1-style final selection shows just one INC card for four identical source IDs",()=>{
 const rows=["a","b","c","d"].map(x=>row(x,pattinson));
 const visible=dedupeNewsRows(rows,rows);
 assert.equal(visible.length,1);
 assert.equal(visible[0].event_id,rows[0].event_id);
});
test("an already prepared story takes precedence over another duplicate incident",()=>{
 const rows=[row("a",pattinson),row("b",pattinson,"ready")];
 assert.equal(dedupeNewsRows(rows,rows)[0].group,"ready");
});
test("previous manual dismissal suppresses duplicate incidents but not evidence in GitHub",()=>{
 const rows=[row("a",pattinson),row("b",pattinson)];
 const prefs=[{event_id:rows[0].event_id,revision:1,dismissed:true,incident_hidden:true}];
 assert.equal(dedupeNewsRows(rows.slice(1),rows,{preferences:prefs}).length,0);
 assert.equal(rows.length,2);
});
test("a distinct event days later is not swallowed",()=>{
 const rows=[row("a",pattinson,"incident","2026-11-15T10:00:00Z"),row("b",pattinson)];
 assert.equal(dedupeNewsRows(rows,rows).length,2);
});
test("generic live headlines are not consolidated across unrelated news",()=>{
 const rows=[row("a","Última hora de la campaña electoral"),row("b","Última hora de la campaña electoral")];
 assert.equal(dedupeNewsRows(rows,rows).length,2);
});
test("different concrete facts keep separate cards",()=>{
 const rows=[row("a","El Supremo confirma la condena a Alfonso Rus"),row("b","El Supremo investiga otro caso")];
 assert.equal(dedupeNewsRows(rows,rows).length,2);
});
