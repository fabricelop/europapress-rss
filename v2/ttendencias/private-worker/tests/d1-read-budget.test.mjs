import test from "node:test";
import assert from "node:assert/strict";
import {newsTables} from "../src/news-actions.js";
import {newsMasterTable} from "../src/news-master.js";

test("periodic news reads have persistent indexes without clearing history",async()=>{
 const statements=[];
 const db={prepare(sql){
  statements.push(sql);
  return {async run(){return {success:true};}};
 }};
 await newsTables(db);
 await newsMasterTable(db);
 const indexes=statements.filter(sql=>sql.startsWith("CREATE INDEX IF NOT EXISTS"));
 assert.ok(indexes.some(sql=>/ON news_actions\(created_at,action_id\)/.test(sql)));
 assert.ok(indexes.some(sql=>/ON news_preferences\(json_extract\(body,'\$\.archived'\)/.test(sql)));
 assert.ok(indexes.some(sql=>/ON news_master_flags\(published_at DESC\)/.test(sql)));
 assert.equal(statements.some(sql=>/\b(DELETE FROM|DROP TABLE|TRUNCATE)\b/.test(sql)),false);
});
