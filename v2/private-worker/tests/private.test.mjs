import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const env={
 AUTH_PASSWORD:"An-example-long-unique-password-12345",
 SESSION_SECRET:"an-example-super-secret-longer-than-32-chars-for-tests-only",
 SESSION_HOURS:"720",
 ASSETS:{fetch:async()=>new Response("<h1>Private V2</h1>",{headers:{"content-type":"text/html"}})}
};
const req=(path="/",init={})=>new Request(origin+path,init);
function loginBody(password, extra={}) {
 return req("/api/login",{method:"POST",headers:{"origin":origin,"x-ttv2-action":"1","content-type":"application/json",...extra},body:JSON.stringify({password})});
}

test("no secrets: fail closed",async()=>{
 const response=await worker.fetch(req("/"),{...env,AUTH_PASSWORD:undefined});
 assert.equal(response.status,503);
});

test("anonymous cannot read app.js, assets, images or state",async()=>{
 for(const path of ["/app.js","/styles.css","/manifest.webmanifest","/api/state/web-top30.json","/photo.png"]) {
  const response=await worker.fetch(req(path),env);
  assert.equal(response.status,401,path);
  assert.equal(response.headers.get("cache-control").includes("no-store"),true);
 }
 const page=await worker.fetch(req("/"),env);
 assert.equal(page.status,200);
 assert.match(await page.text(),/Acceso privado/);
 assert.match(page.headers.get("content-security-policy"),/default-src 'none'/);
});

test("login rejects wrong credentials and cross-origin request",async()=>{
 assert.equal((await worker.fetch(loginBody("this-is-not-the-secret"),env)).status,401);
 assert.equal((await worker.fetch(loginBody(env.AUTH_PASSWORD,{"origin":"https://evil.example"}),env)).status,403);
 assert.equal((await worker.fetch(req("/api/login",{method:"GET"}),env)).status,403);
});

test("login sets HttpOnly cookie, app accessible, logout revokes browser cookie",async()=>{
 const response=await worker.fetch(loginBody(env.AUTH_PASSWORD),env);
 assert.equal(response.status,200);
 const cookie=response.headers.get("set-cookie");
 assert.match(cookie,/__Host-ttv2=v1\./);
 assert.match(cookie,/HttpOnly/);
 assert.match(cookie,/SameSite=Strict/);
 assert.match(cookie,/Secure/);
 assert.match(cookie,/Max-Age=2592000/);
 const value=cookie.split(";")[0];
 const privateReq=(path,options={})=>req(path,{...options,headers:{"cookie":value,...options.headers}});
 const page=await worker.fetch(privateReq("/"),env);
 assert.equal(page.status,200);
 assert.match(await page.text(),/Private V2/);
 assert.equal((await worker.fetch(privateReq("/api/me"),env)).status,200);
 assert.equal((await worker.fetch(privateReq("/api/action",{method:"POST",headers:{"origin":origin,"x-ttv2-action":"1"}}),env)).status,503);
 const logout=await worker.fetch(privateReq("/api/logout",{method:"POST",headers:{"origin":origin,"x-ttv2-action":"1"}}),env);
 assert.equal(logout.status,200);
 assert.match(logout.headers.get("set-cookie"),/Max-Age=0/);
});

test("invalid cookie tampering and rotated signature cannot authenticate",async()=>{
 const response=await worker.fetch(loginBody(env.AUTH_PASSWORD),env);
 const value=response.headers.get("set-cookie").split(";")[0];
 const tampered=value.slice(0,-1)+(value.endsWith("A")?"B":"A");
 assert.equal((await worker.fetch(req("/app.js",{headers:{"cookie":tampered}}),env)).status,401);
 const otherEnv={...env,SESSION_SECRET:"different-test-signature-key-1234567890"};
 assert.equal((await worker.fetch(req("/app.js",{headers:{"cookie":value}}),otherEnv)).status,401);
});

test("the backend does not accept unauthorized POST actions",async()=>{
 const response=await worker.fetch(req("/api/reelaborar",{method:"POST",headers:{"origin":origin,"x-ttv2-action":"1"}}),env);
 assert.equal(response.status,401);
});

test("Cloudflare login rate limit fails closed at threshold",async()=>{
 const guarded={...env,LOGIN_LIMITER:{limit:async()=>({success:false})}};
 const blocked=await worker.fetch(loginBody(env.AUTH_PASSWORD),guarded);
 assert.equal(blocked.status,429);
 assert.equal(blocked.headers.get("retry-after"),"60");
 assert.equal(blocked.headers.get("set-cookie"),null);
});

test("session expiry is exactly 30 days, not more",async()=>{
 const response=await worker.fetch(loginBody(env.AUTH_PASSWORD),env);
 const token=response.headers.get("set-cookie").split(";")[0];
 const parts=token.split("=")[1].split(".");
 const expires=Number(parts[1]);
 assert.ok(expires>Date.now()+29*24*3600000);
 assert.ok(expires<=Date.now()+30*24*3600000);
 const ok=await worker.fetch(req("/api/me",{headers:{"cookie":token}}),env);
 assert.equal(ok.status,200);
});
