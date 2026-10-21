const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  deliverAssistantItem,
  loadState,
  retryDelayMs
} = require('./assistant_delivery');

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'slr-delivery-'));
  return {
    dir,
    stateFile: path.join(dir, 'state.json'),
    legacySentFile: path.join(dir, 'sent.json'),
    key: 'evaluate:123',
    item: {
      request_key: 'evaluate:123',
      created_at: '2026-09-30T17:20:00.000Z',
      telegram_text: 'cabecera',
      alternatives: ['a', 'b'],
      original_url: 'https://x.com/example/status/123'
    },
    steps: ['header', 'a', 'b', 'footer'].map(name => ({ payload: { name } }))
  };
}

test('reanuda por el primer paso no confirmado sin duplicar los anteriores', async t => {
  const f = fixture();
  t.after(() => fs.rmSync(f.dir, { recursive: true, force: true }));
  const sent = [];
  let calls = 0;
  const first = await deliverAssistantItem({
    ...f,
    now: () => new Date('2026-09-30T17:30:00.000Z'),
    sendMessage: async payload => {
      calls++;
      if (calls === 3) throw new Error('fallo temporal');
      sent.push(payload.name);
      return { message_id: 100 + calls };
    }
  });
  assert.equal(first.status, 'pending');
  assert.deepEqual(sent, ['header', 'a']);
  assert.equal(loadState(f.stateFile).deliveries[f.item.request_key].next_step, 2);

  const resumed = await deliverAssistantItem({
    ...f,
    now: () => new Date('2026-09-30T17:40:00.000Z'),
    sendMessage: async payload => {
      sent.push(payload.name);
      return { message_id: 200 + sent.length };
    }
  });
  assert.equal(resumed.status, 'delivered');
  assert.deepEqual(sent, ['header', 'a', 'b', 'footer']);

  let duplicateCalls = 0;
  const repeated = await deliverAssistantItem({
    ...f,
    now: () => new Date('2026-09-30T18:00:00.000Z'),
    sendMessage: async () => { duplicateCalls++; return { message_id: 999 }; }
  });
  assert.equal(repeated.status, 'delivered');
  assert.equal(repeated.skipped, true);
  assert.equal(duplicateCalls, 0);
});

test('migra el registro legado y no reenvía una salida ya entregada', async t => {
  const f = fixture();
  t.after(() => fs.rmSync(f.dir, { recursive: true, force: true }));
  fs.writeFileSync(f.legacySentFile, JSON.stringify({ [f.item.request_key]: { sent_at: '2026-09-30T17:00:00.000Z' } }));
  let calls = 0;
  const result = await deliverAssistantItem({
    ...f,
    sendMessage: async () => { calls++; return { message_id: 1 }; }
  });
  assert.equal(result.skipped, true);
  assert.equal(calls, 0);
  assert.equal(loadState(f.stateFile).deliveries[f.item.request_key].migrated_from_legacy, true);
});

test('bloquea un cambio de fuente tras una entrega parcial', async t => {
  const f = fixture();
  t.after(() => fs.rmSync(f.dir, { recursive: true, force: true }));
  let calls = 0;
  await deliverAssistantItem({
    ...f,
    now: () => new Date('2026-09-30T17:30:00.000Z'),
    sendMessage: async () => {
      calls++;
      if (calls === 2) throw new Error('corte');
      return { message_id: 10 };
    }
  });
  const changed = { ...f.item, telegram_text: 'otra versión' };
  const result = await deliverAssistantItem({
    ...f,
    item: changed,
    now: () => new Date('2026-09-30T18:00:00.000Z'),
    sendMessage: async () => ({ message_id: 20 })
  });
  assert.equal(result.status, 'blocked');
  assert.match(result.error, /cambió durante una entrega parcial/);
});

test('el backoff crece y queda limitado', () => {
  assert.equal(retryDelayMs(1), 5000);
  assert.equal(retryDelayMs(2), 10000);
  assert.equal(retryDelayMs(20), 300000);
});
