import test from "node:test";
import assert from "node:assert/strict";
import worker,{authorize,inputCheck} from "../src/index.js";

const img="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/example-r1.jpg";
const item={source:"ttittulares",event_id:"abcde123",revision:1,telegram_message_id:200,image_url:img,caption:"Texto aprobado\n\nIlustración generada con IA."};
const secret="only-test-not-a-production-credential-1234";

test("health never declares the Instagram publisher activated",async()=>{
  const r=await worker.fetch(new Request("https://example.com/health"),{});
  assert.equal(r.status,200);
  assert.equal((await r.json()).active,false);
});
test("no anonymous or short-secret publication",async()=>{
  const req=new Request("https://example.com/publish",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(item)});
  const r=await worker.fetch(req,{INSTAGRAM_INTERNAL_SECRET:secret});
  assert.equal(r.status,401);
  assert.equal(authorize(new Request("https://example.com",{headers:{authorization:"Bearer abc"}}),{INSTAGRAM_INTERNAL_SECRET:"abc"}),false);
});
test("valid inputs and restricted image host",()=>{
  const validated=inputCheck(item);
  assert.equal(validated.key,"ttittulares:abcde123");
  for(const image of ["https://evil.test/img.jpg","https://raw.githubusercontent.com/other/repo/main/ttittulares/generated-images/a.jpg","https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/a.png"]){
    assert.throws(()=>inputCheck({...item,image_url:image}));
  }
  assert.throws(()=>inputCheck({...item,caption:""}));
  assert.throws(()=>inputCheck({...item,telegram_message_id:0}));
  assert.throws(()=>inputCheck({...item,source:"other"}));
});
test("authenticated but unconfigured publisher fails closed",async()=>{
  const req=new Request("https://example.com/publish",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer "+secret},body:JSON.stringify(item)});
  const r=await worker.fetch(req,{INSTAGRAM_INTERNAL_SECRET:secret});
  assert.equal(r.status,503);
  assert.equal((await r.json()).error,"NOT_CONFIGURED");
});


function fakeDb(){
  let row;
  return {
    prepare(sql){
      return {bind(...args){
        return {
          async first(){return row?{...row}:null;},
          async run(){
            if(sql.startsWith("INSERT OR IGNORE")){
              if(!row){const [id,source,event_id,revision,telegram_message_id,image_url,caption]=args;
                row={id,source,event_id,revision,telegram_message_id,image_url,caption,state:"reserved"};
                return {meta:{changes:1}};
              }
              return {meta:{changes:0}};
            }
            if(sql.startsWith("UPDATE instagram_posts SET permalink")){
              if(row&&row.id===args[1]){row.permalink=args[0];return {meta:{changes:1}};}
              return {meta:{changes:0}};
            }
            if(sql.startsWith("UPDATE instagram_posts SET state")){
              const state=args[0],key=args.at(-2),old=args.at(-1);
              if(!row||row.id!==key||row.state!==old)return {meta:{changes:0}};
              const fields=[...sql.matchAll(/,(container_id|media_id)=\?/g)].map(x=>x[1]);
              fields.forEach((field,i)=>row[field]=args[i+1]);
              row.state=state;
              return {meta:{changes:1}};
            }
            throw Error("Unexpected query "+sql);
          }
        };
      }};
    },
    snapshot(){return row?{...row}:null;}
  };
}
function makePost(){return new Request("https://preview.example/publish",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer "+secret},body:JSON.stringify(item)});}

test("one selected message results in at most one public post",async()=>{
  const db=fakeDb(),originalFetch=globalThis.fetch;
  let publishes=0,containers=0;
  globalThis.fetch=async(url,options)=>{
    const route=new URL(url).pathname;
    assert.equal(options.headers.authorization,"Bearer page-token");
    if(route.endsWith("/media")){containers++;return Response.json({id:"1234567890"});}
    if(route.endsWith("/1234567890"))return Response.json({status_code:"FINISHED"});
    if(route.endsWith("/media_publish")){publishes++;return Response.json({id:"9876543210"});}
    if(route.endsWith("/9876543210"))return Response.json({permalink:"https://www.instagram.com/p/TEST/"});
    throw Error("Unexpected URL "+url);
  };
  const env={INSTAGRAM_INTERNAL_SECRET:secret,INSTAGRAM_PAGE_ACCESS_TOKEN:"page-token",INSTAGRAM_USER_ID:"17841414511690117",IG_DB:db};
  try {
    const first=await (await worker.fetch(makePost(),env)).json();
    assert.equal(first.state,"published");
    assert.equal(first.permalink,"https://www.instagram.com/p/TEST/");
    const second=await (await worker.fetch(makePost(),env)).json();
    assert.equal(second.duplicate,true);
    assert.equal(containers,1);
    assert.equal(publishes,1);
  }finally{globalThis.fetch=originalFetch;}
});
test("ambiguous media_publish response blocks double posting",async()=>{
  const db=fakeDb(),originalFetch=globalThis.fetch;
  let publishes=0;
  globalThis.fetch=async(url)=>{
    const route=new URL(url).pathname;
    if(route.endsWith("/media"))return Response.json({id:"1234567890"});
    if(route.endsWith("/1234567890"))return Response.json({status_code:"FINISHED"});
    if(route.endsWith("/media_publish")){publishes++;throw Error("connection lost");}
    throw Error("Unexpected URL "+url);
  };
  const env={INSTAGRAM_INTERNAL_SECRET:secret,INSTAGRAM_PAGE_ACCESS_TOKEN:"page-token",INSTAGRAM_USER_ID:"17841414511690117",IG_DB:db};
  try{
    const first=await worker.fetch(makePost(),env);
    assert.equal(first.status,503);
    assert.equal((await first.json()).state,"uncertain");
    const retry=await worker.fetch(makePost(),env);
    assert.equal(retry.status,409);
    assert.equal(publishes,1);
    assert.equal(db.snapshot().state,"uncertain");
  }finally{globalThis.fetch=originalFetch;}
});
