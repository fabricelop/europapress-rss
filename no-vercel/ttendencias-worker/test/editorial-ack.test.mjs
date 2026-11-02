import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

test('editorial ACK accepts supported listeners and preserves claim/command guards', async () => {
  const originalFetch = globalThis.fetch;
  const originalToken = process.env.GITHUB_TOKEN;
  let writes = 0;
  let prior = null;
  const current = {command_id: 'current-test-command', requested_at: new Date().toISOString()};
  globalThis.fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    assert.ok(String(url).startsWith('https://api.github.com/repos/'));
    if (options.method === 'PUT') {
      assert.ok(path.endsWith('/trends/run-ack.json'));
      prior = JSON.parse(Buffer.from(JSON.parse(options.body).content, 'base64').toString());
      writes++;
      return Response.json({commit: {sha: 'test-commit'}});
    }
    if (path.endsWith('/trends/run-now-trigger.json')) return Response.json({sha:'trigger-sha', content:Buffer.from(JSON.stringify(current)).toString('base64')});
    if (path.endsWith('/trends/run-ack.json')) return prior ? Response.json({sha:'ack-sha',content:Buffer.from(JSON.stringify(prior)).toString('base64')}) : new Response('',{status:404});
    throw new Error('Unexpected network request: ' + url);
  };
  async function ack(worker_id, command_id = current.command_id, stage = 'picked_up') {
    const r = await worker.fetch(new Request('https://test.example/api/ttendencias-run', {method:'POST',body:JSON.stringify({task:'pc_ack',worker_id,command_id,stage})}),{GITHUB_TOKEN:'test-only-token'});
    return {status:r.status,doc:await r.json()};
  }
  try {
    for (const version of [12,20,21]) {
      prior = null;
      assert.equal((await ack('ttendencias-dedicated-v'+version)).status,200);
      assert.equal((await ack('ttendencias-dedicated-v'+version,current.command_id,'launched')).status,200);
    }
    const before = writes;
    for (const id of ['ttendencias-dedicated-v11','legacy-shared-listener','ttendencias-dedicated-vx','ttendencias-dedicated-v20-extra']) {
      assert.equal((await ack(id)).doc.error,'stale_worker');
    }
    assert.equal(writes,before);
    assert.equal((await ack('ttendencias-dedicated-v20','old-command')).doc.error,'command_id ya no es el actual');
    assert.equal((await ack('ttendencias-dedicated-v20')).doc.error,'claimed_by_other_worker');
    assert.equal(writes,before);
  } finally {
    globalThis.fetch = originalFetch;
    if (originalToken === undefined) delete process.env.GITHUB_TOKEN;
    else process.env.GITHUB_TOKEN = originalToken;
  }
});
