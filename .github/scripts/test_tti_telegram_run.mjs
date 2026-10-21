// Tests offline: no Telegram, GitHub ni Cloudflare reales.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

for (const filename of ['api/telegram-webhook.js', 'vercel-webhook/api/telegram-webhook.js']) {
  const sends = [];
  const writes = [];
  let stored = { command_id: 'tt-old', requested_at: '2026-09-01T00:00:00Z' };
  const fakeFetch = async (url, options = {}) => {
    if (String(url).includes('api.github.com/repos/') && String(url).includes('/contents/ttittulares/run-now-trigger.json')) {
      if (options.method === 'PUT') {
        const body = JSON.parse(options.body);
        const doc = JSON.parse(Buffer.from(body.content, 'base64').toString('utf8'));
        assert.equal(body.branch, 'control/ttittulares-run-trigger-v2');
        assert.equal(doc.project, 'ttittulares');
        assert.equal(doc.launcher_arg, 'titulares');
        assert.equal(doc.executor, 'pc_chat_ttittulares_dedicated');
        writes.push(doc);
        stored = doc;
        return {ok:true, status:200, json:async()=>({})};
      }
      return {ok:true, status:200, json:async()=>({
        sha:'sha-dummy', content:Buffer.from(JSON.stringify(stored)).toString('base64')
      })};
    }
    if (String(url).includes('api.telegram.org/bot')) {
      const p=JSON.parse(options.body);
      sends.push(p);
      return {ok:true,status:200,json:async()=>({ok:true,result:{message_id:123}})};
    }
    throw new Error('Unexpected network URL: '+url);
  };
  const source=fs.readFileSync(filename,'utf8')
    .replace('export default async function handler','async function handler');
  const ctx=vm.createContext({
    fetch:fakeFetch, process:{env:{
      GITHUB_REPO:'fabricelop/europapress-rss',GITHUB_BRANCH:'main',
      GITHUB_TOKEN:'test-token',TELEGRAM_BOT_TOKEN:'bot-token',TELEGRAM_CHAT_ID:'1234',
      TELEGRAM_WEBHOOK_SECRET:'test-secret'
    }},Buffer,console,Date,Math,URL,setTimeout
  });
  vm.runInContext(source+'\nthis.__test={requestTtiWindowsRun,handler};',ctx,{filename});
  const first=await ctx.__test.requestTtiWindowsRun();
  assert.equal(first.status,'requested');
  assert.equal(writes.length,1);
  const second=await ctx.__test.requestTtiWindowsRun();
  assert.equal(second.status,'already_requested');
  assert.equal(writes.length,1);
  stored={ command_id: 'tt-old', requested_at: '2026-09-01T00:00:00Z' };
  const deniedRes={
    code:200, status(code){this.code=code;return this;},
    json(data){this.data=data;return this;}
  };
  await ctx.__test.handler({
    method:'POST',headers:{},
    body:{update_id:99,message:{chat:{id:1234,type:'private'},text:'/run'}}
  },deniedRes);
  assert.equal(deniedRes.code,401);
  assert.equal(writes.length,1);
  const res={
    code:200, status(code){this.code=code;return this;},
    json(data){this.data=data;return this;}
  };
  const answer=await ctx.__test.handler({
    method:'POST',headers:{'x-telegram-bot-api-secret-token':'test-secret'},
    body:{update_id:100,message:{chat:{id:1234,type:'private'},text:'/run'}}
  },res);
  assert.equal(answer.code,200);
  assert.equal(writes.length,2);
  assert.equal(sends.length,1);
  assert.match(sends[0].text,/solicitud \/run guardada/);
  console.log(filename+': Telegram /run GH trigger + dedupe + ACK OK');
}
