const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_) { return fallback; }
}

function writeJsonAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(data, null, 2) + '\n', 'utf8');
  try {
    fs.renameSync(temp, file);
  } catch (error) {
    try { fs.rmSync(file, { force: true }); fs.renameSync(temp, file); }
    catch (_) { fs.rmSync(temp, { force: true }); throw error; }
  }
}

function assistantFingerprint(item) {
  const source = {
    request_key: String(item && item.request_key || ''),
    created_at: String(item && item.created_at || ''),
    telegram_text: String(item && item.telegram_text || item && item.content || ''),
    alternatives: Array.isArray(item && item.alternatives) ? item.alternatives.map(String) : [],
    original_url: String(item && item.original_url || '')
  };
  return crypto.createHash('sha256').update(JSON.stringify(source)).digest('hex');
}

function retryDelayMs(failures) {
  return Math.min(5 * 60 * 1000, 5000 * (2 ** Math.max(0, Math.min(Number(failures || 1) - 1, 6))));
}

function loadState(stateFile) {
  const doc = readJson(stateFile, { version: 1, deliveries: {} });
  if (!doc || typeof doc !== 'object') return { version: 1, deliveries: {} };
  doc.version = 1;
  if (!doc.deliveries || typeof doc.deliveries !== 'object') doc.deliveries = {};
  return doc;
}

function saveState(stateFile, doc) {
  doc.updated_at = new Date().toISOString();
  writeJsonAtomic(stateFile, doc);
}

function acquireLock(lockFile, staleMs = 10 * 60 * 1000) {
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  const open = () => {
    const fd = fs.openSync(lockFile, 'wx');
    fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, created_at: new Date().toISOString() }) + '\n');
    return {
      release() {
        try { fs.closeSync(fd); } catch (_) {}
        try { fs.rmSync(lockFile, { force: true }); } catch (_) {}
      }
    };
  };
  try { return open(); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    try {
      const age = Date.now() - fs.statSync(lockFile).mtimeMs;
      if (age > staleMs) {
        fs.rmSync(lockFile, { force: true });
        return open();
      }
    } catch (_) {}
    return null;
  }
}

function recordAssistantDeliveryError({ key, item, stateFile, error }) {
  if (!key) return;
  const doc = loadState(stateFile);
  const old = doc.deliveries[key] || {};
  doc.deliveries[key] = {
    ...old,
    fingerprint: assistantFingerprint(item),
    status: 'invalid',
    last_error: String(error && (error.message || error) || 'salida inválida'),
    last_attempt_at: new Date().toISOString(),
    next_retry_at: null
  };
  saveState(stateFile, doc);
}

async function deliverAssistantItem({
  key,
  item,
  steps,
  stateFile,
  legacySentFile,
  sendMessage,
  now = () => new Date()
}) {
  if (!key) throw new Error('request_key ausente');
  if (!Array.isArray(steps) || !steps.length) throw new Error('la entrega no contiene mensajes');
  const fingerprint = assistantFingerprint(item);
  const state = loadState(stateFile);
  const legacySent = readJson(legacySentFile, {});
  let record = state.deliveries[key];

  if (!record && legacySent[key]) {
    record = state.deliveries[key] = {
      fingerprint,
      status: 'delivered',
      migrated_from_legacy: true,
      delivered_at: legacySent[key].sent_at || now().toISOString(),
      next_step: steps.length,
      message_ids: []
    };
    saveState(stateFile, state);
    return { status: 'delivered', skipped: true, message_ids: [] };
  }

  if (!record) {
    record = state.deliveries[key] = {
      fingerprint,
      status: 'pending',
      attempts: 0,
      failures: 0,
      next_step: 0,
      message_ids: []
    };
    saveState(stateFile, state);
  } else if (record.fingerprint !== fingerprint) {
    if (record.status === 'delivered') {
      record.status = 'blocked';
      record.last_error = 'assistant-output cambió después de una entrega confirmada; no se reenvía para evitar duplicados';
    } else if (Number(record.next_step || 0) > 0) {
      record.status = 'blocked';
      record.last_error = 'assistant-output cambió durante una entrega parcial; requiere revisión para no mezclar versiones';
    } else {
      Object.assign(record, {
        fingerprint,
        status: 'pending',
        attempts: 0,
        failures: 0,
        next_step: 0,
        message_ids: [],
        next_retry_at: null,
        last_error: null
      });
    }
    saveState(stateFile, state);
    if (record.status === 'blocked') return { status: 'blocked', error: record.last_error, message_ids: record.message_ids || [] };
  }

  if (record.status === 'delivered') {
    return { status: 'delivered', skipped: true, message_ids: record.message_ids || [] };
  }
  if (record.status === 'blocked') {
    return { status: 'blocked', error: record.last_error, message_ids: record.message_ids || [] };
  }

  const current = now();
  if (record.next_retry_at && new Date(record.next_retry_at).getTime() > current.getTime()) {
    return { status: 'pending', deferred: true, next_retry_at: record.next_retry_at, message_ids: record.message_ids || [] };
  }

  record.attempts = Number(record.attempts || 0) + 1;
  record.last_attempt_at = current.toISOString();
  record.status = 'sending';
  saveState(stateFile, state);

  for (let index = Number(record.next_step || 0); index < steps.length; index++) {
    try {
      const result = await sendMessage(steps[index].payload);
      if (!result || !Number(result.message_id)) throw new Error('Telegram no devolvió message_id');
      record.message_ids[index] = Number(result.message_id);
      record.next_step = index + 1;
      record.status = 'pending';
      record.last_error = null;
      record.next_retry_at = null;
      saveState(stateFile, state);
    } catch (error) {
      record.failures = Number(record.failures || 0) + 1;
      record.status = 'pending';
      record.last_error = String(error && (error.message || error) || error);
      record.next_retry_at = new Date(current.getTime() + retryDelayMs(record.failures)).toISOString();
      saveState(stateFile, state);
      return {
        status: 'pending',
        error: record.last_error,
        next_retry_at: record.next_retry_at,
        message_ids: record.message_ids || []
      };
    }
  }

  record.status = 'delivered';
  record.delivered_at = now().toISOString();
  record.next_retry_at = null;
  record.last_error = null;
  saveState(stateFile, state);
  legacySent[key] = { sent_at: record.delivered_at, fingerprint };
  writeJsonAtomic(legacySentFile, legacySent);
  return { status: 'delivered', message_ids: record.message_ids || [] };
}

module.exports = {
  acquireLock,
  assistantFingerprint,
  deliverAssistantItem,
  loadState,
  recordAssistantDeliveryError,
  retryDelayMs,
  writeJsonAtomic
};
