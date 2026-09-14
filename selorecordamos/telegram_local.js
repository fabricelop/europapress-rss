const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const baseDir = __dirname;
const outboxFile = path.join(baseDir, 'telegram-outbox.json');
const candidatesDir = path.join(baseDir, 'candidates');
const runtimeDir = path.join(baseDir, 'runtime');
const stateFile = path.join(runtimeDir, 'telegram-state.json');
const requestsFile = path.join(baseDir, 'requests.json');

fs.mkdirSync(runtimeDir, { recursive: true });

const token = process.env.SR_TELEGRAM_BOT_TOKEN || '';
const chatId = String(process.env.SR_TELEGRAM_CHAT_ID || '');
if (!token || !chatId) {
  console.error('Faltan SR_TELEGRAM_BOT_TOKEN y/o SR_TELEGRAM_CHAT_ID.');
  process.exit(2);
}

const api = (method) => `https://api.telegram.org/bot${token}/${method}`;

async function telegram(method, payload = {}) {
  const r = await fetch(api(method), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const data = await r.json();
  if (!data.ok) throw new Error(`Telegram ${method}: ${JSON.stringify(data)}`);
  return data.result;
}

async function safeAnswerCallbackQuery(callbackQueryId, text) {
  try {
    await telegram('answerCallbackQuery', { callback_query_id: callbackQueryId, text });
  } catch (e) {
    const m = String(e && e.message ? e.message : e);
    if (/query is too old|query ID is invalid|response timeout expired/i.test(m)) {
      console.log('Callback antiguo descartado.');
      return;
    }
    throw e;
  }
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_) { return fallback; }
}

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

function localTime(value) {
  if (!value) return 'hora desconocida';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return new Intl.DateTimeFormat('es-ES', {
    timeZone: 'Europe/Madrid', day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false
  }).format(d).replace(',', '');
}

async function sendOutbox() {
  const data = readJson(outboxFile, { candidates: [] });
  const sent = readJson(path.join(runtimeDir, 'telegram-sent.json'), {});
  let changed = false;
  let index = 1;

  for (const c of data.candidates || []) {
    const id = String(c.id || '');
    if (!id || sent[id]) continue;
    const visible = `🧠 SELORECORDAMOS · SR${index}\n${c.user || ''} · ${localTime(c.datetime)}\n\n${String(c.text || '').trim()}`;
    await telegram('sendMessage', {
      chat_id: chatId,
      text: visible,
      disable_web_page_preview: true,
      reply_markup: {
        inline_keyboard: [
          [{ text: '🔗 Abrir original en X', url: c.url }],
          [
            { text: '🧠 Evaluar', callback_data: `sr:evaluate:${id}` },
            { text: '🗑️ Borrar', callback_data: `sr:delete:${id}` }
          ]
        ]
      }
    });
    sent[id] = { sent_at: new Date().toISOString() };
    changed = true;
    index++;
  }
  if (changed) writeJson(path.join(runtimeDir, 'telegram-sent.json'), sent);
}

function gitPushRequest() {
  try {
    cp.execFileSync('git', ['add', 'selorecordamos/requests.json'], { cwd: path.join(baseDir, '..'), stdio: 'ignore' });
    const diff = cp.spawnSync('git', ['diff', '--cached', '--quiet'], { cwd: path.join(baseDir, '..') });
    if (diff.status === 0) return;
    cp.execFileSync('git', ['commit', '-m', 'Queue SeLoRecordamos evaluation'], { cwd: path.join(baseDir, '..'), stdio: 'ignore' });
    cp.execFileSync('git', ['push', 'origin', 'main'], { cwd: path.join(baseDir, '..'), stdio: 'ignore' });
  } catch (e) {
    console.error('No se pudo subir requests.json a GitHub:', e.message);
  }
}

async function pollCallbacksOnce() {
  const state = readJson(stateFile, { offset: 0 });
  const url = new URL(api('getUpdates'));
  url.searchParams.set('offset', String(state.offset || 0));
  url.searchParams.set('timeout', '25');
  url.searchParams.set('allowed_updates', JSON.stringify(['callback_query']));
  const r = await fetch(url);
  const data = await r.json();
  if (!data.ok) throw new Error(JSON.stringify(data));

  const queue = readJson(requestsFile, { requests: [] });
  queue.requests ||= [];
  let queueChanged = false;

  for (const update of data.result || []) {
    state.offset = Math.max(Number(state.offset || 0), Number(update.update_id) + 1);
    const cq = update.callback_query;
    if (!cq) continue;
    const msg = cq.message || {};
    if (String((msg.chat || {}).id || '') !== chatId) continue;
    const cb = String(cq.data || '');
    const parts = cb.split(':');
    if (parts[0] !== 'sr' || parts.length < 3) continue;
    const action = parts[1];
    const id = parts[2];

    if (action === 'delete') {
      await safeAnswerCallbackQuery(cq.id, '🗑️ Candidato quitado.');
      await telegram('deleteMessage', { chat_id: chatId, message_id: msg.message_id });
      console.log(`Borrado ${id}`);
      continue;
    }

    if (action === 'evaluate') {
      const candidateFile = path.join(candidatesDir, `${id}.json`);
      const candidate = readJson(candidateFile, null);
      if (!candidate) {
        await safeAnswerCallbackQuery(cq.id, 'No encuentro este candidato.');
        continue;
      }
      if (!queue.requests.some(x => x.type === 'evaluate' && x.tweet_id === id)) {
        queue.requests.push({
          created_at: new Date().toISOString(),
          type: 'evaluate',
          tweet_id: id,
          user: candidate.user,
          text: candidate.text,
          url: candidate.url
        });
        queue.requests = queue.requests.slice(-100);
        queueChanged = true;
      }
      await safeAnswerCallbackQuery(cq.id, '🧠 Candidato enviado para evaluar.');
      await telegram('deleteMessage', { chat_id: chatId, message_id: msg.message_id });
      console.log(`Evaluar ${id}`);
    }
  }

  writeJson(stateFile, state);
  if (queueChanged) {
    writeJson(requestsFile, queue);
    gitPushRequest();
  }
}

async function pollForever() {
  console.log('SeLoRecordamos Telegram activo. Escuchando botones...');
  while (true) {
    try {
      await pollCallbacksOnce();
    } catch (e) {
      console.error('Error escuchando Telegram:', e.message || e);
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
  }
}

(async () => {
  const mode = process.argv[2] || 'all';
  if (mode === 'send' || mode === 'all') await sendOutbox();
  if (mode === 'poll' || mode === 'all') await pollForever();
})().catch(e => {
  console.error(e.stack || e);
  process.exit(1);
});
