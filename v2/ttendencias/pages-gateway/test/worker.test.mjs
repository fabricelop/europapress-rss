import test from "node:test";
import assert from "node:assert/strict";
import worker from "../dist/_worker.js";

const origin="https://ttactualidad-v2-rescate.pages.dev";
test("Pages conserva el mismo origen para la contraseña y el control PU",async()=>{
  for(const path of ["/api/login","/api/publication-count","/api/marks"]){
    const request=new Request(origin+path,{method:"POST",headers:{origin,"x-ttv2-action":"1","cookie":"ttv2_session=ficticia"},body:"{}"});
    const response=await worker.fetch(request,{V2_ORIGIN:{fetch:async forwarded=>{
      assert.equal(forwarded,request);
      assert.equal(forwarded.headers.get("origin"),new URL(forwarded.url).origin);
      return new Response("{}",{status:401,headers:{"cache-control":"no-store"}});
    }}});
    assert.equal(response.status,401);
    assert.equal(response.headers.get("cache-control"),"no-store");
  }
});
test("Pages no sirve contenido sin el vínculo autorizado",async()=>{
  const response=await worker.fetch(new Request(origin+"/"),{});
  assert.equal(response.status,503);
});
