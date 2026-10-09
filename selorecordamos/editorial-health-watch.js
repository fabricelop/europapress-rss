'use strict';

// Vigilancia independiente del editor de ChatGPT. Solo lee GitHub y avisa a
// Telegram cuando una solicitud aceptada sigue sin materializarse.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const baseDir = __dirname;
const runtime = path.join(baseDir, 'runtime');
const alertStatePath = path.join(runtime, 'editorial-health-watch-state.json');
const rawBase = 'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/selorecordamos';
const staleAfterMs = 90 * 60 * 1000;
const renotifyAfterMs = 3 * 60 * 60 * 1000;

function keyOf(request) {
  if (request && request.type === 'evaluate' && request.tweet_id) return `evaluate:${request.tweet_id}`;
  if (request && request.type === 'telegram_instruction' && request.telegram_update_id != null) {
    return `telegram_instruction:${request.telegram_update_id}`;
  }
  return '';
}

function isComplete(item, type) {
  if (!item || item.send_to_telegram !== true || !String(item.telegram_text || '').trim()) return false;
  if (type === 'evaluate') {
    return Array.isArray(item.alternatives) && item.alternatives.length === 4 &&
      item.alternatives.every(s => typeof s === 'string' && s.trim().length > 0 && s.length <= 256);
  }
  return Array.isArray(item.alternatives) && [0, 4].includes(item.alternatives.length);
}

function inspectEditorial(requestsDoc, stateDoc, outputDoc, nowMs = Date.now()) {
  const processed = new Set(Array.isArray(stateDoc.processed) ? stateDoc.processed : []);
  const outputs = new Map((Array.isArray(outputDoc.outputs) ? outputDoc.outputs : [])
    .filter(item => item && item.request_key).map(item => [item.request_key, item]));
  const pending = [], inconsistent = [];
  const seen = new Set();
  for (const request of (Array.isArray(requestsDoc.requests) ? requestsDoc.requests : [])) {
    const key = keyOf(request);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    const createdAtMs = Date.parse(String(request.created_at || ''));
    const ageMs = Number.isFinite(createdAtMs) ? Math.max(0, nowMs - createdAtMs) : null;
    const row = { key, ageMs, createdAt: request.created_at || null };
    if (!processed.has(key)) {
      if (ageMs !== null) pending.push(row);
    } else if (!isComplete(outputs.get(key), request.type)) {
      // Solo solicitudes retenidas: processed conserva más historia que outputs.
      inconsistent.push(row);
    }
  }
  const overdue = pending.filter(item => item.ageMs > staleAfterMs).sort((a, b) => b.ageMs - a.ageMs);
  return { overdue, pendingCount: pending.length, inconsistent, checked: seen.size };
}

async function readGitHubJson(filename) {
  const url = `${rawBase}/${filename}?editorial_health=${Date.now()}`;
  const response = await fetch(url, { signal: AbortSignal.timeout(14000), cache: 'no-store' });
  if (!response.ok) throw new Error(`${filename} HTTP ${response.status}`);
  return response.json();
}

function readLastAlert() {
  try { return JSON.parse(fs.readFileSync(alertStatePath, 'utf8')); }
  catch (_) { return {}; }
}

function saveLastAlert(value) {
  fs.mkdirSync(runtime, { recursive: true });
  const temp = `${alertStatePath}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', 'utf8');
  try { fs.renameSync(temp, alertStatePath); }
  catch (_) { fs.rmSync(alertStatePath, { force: true }); fs.renameSync(temp, alertStatePath); }
}

function buildAlert(health) {
  const oldest = health.overdue[0];
  const lines = [
    '⚠️ SeLoRecordamos · Redacción editorial atascada',
    `${health.pendingCount} solicitudes pendientes; ${health.overdue.length} llevan más de 90 minutos sin procesar.`,
  ];
  if (oldest) lines.push(`Más antigua: ${oldest.key} (${Math.round(oldest.ageMs / 60000)} min).`);
  if (health.inconsistent.length) lines.push(`${health.inconsistent.length} solicitudes marcadas como procesadas sin salida completa.`);
  lines.push('Comprobar la automatización ChatGPT «SeLoRecordamos Evaluaciones». Telegram no puede enviar alternativas que todavía no existen.');
  return lines.join('\n');
}

async function telegramAlert(message) {
  const token = process.env.SR_TELEGRAM_BOT_TOKEN;
  const chatId = process.env.SR_TELEGRAM_CHAT_ID;
  if (!token || !chatId) throw new Error('Falta la configuración de Telegram en este proceso');
  const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: message, disable_web_page_preview: true }),
    signal: AbortSignal.timeout(14000)
  });
  const data = await response.json();
  if (!response.ok || !data.ok) throw new Error(`Telegram rechazó alerta (HTTP ${response.status})`);
}

async function main() {
  const [requests, state, outputs] = await Promise.all([
    readGitHubJson('requests.json'),
    readGitHubJson('assistant-state.json'),
    readGitHubJson('assistant-output.json')
  ]);
  const health = inspectEditorial(requests, state, outputs);
  if (!health.overdue.length && !health.inconsistent.length) {
    console.log(`EDITORIAL OK: ${health.pendingCount} pendientes recientes, ninguna vencida; ${health.checked} solicitudes comprobadas.`);
    return;
  }
  const affected = [...health.overdue, ...health.inconsistent].map(item => item.key).sort();
  const signature = crypto.createHash('sha256').update(affected.join('|')).digest('hex');
  const previous = readLastAlert();
  const nowMs = Date.now();
  if (previous.signature === signature && nowMs - Date.parse(previous.sent_at || 0) < renotifyAfterMs) {
    console.log(`EDITORIAL ALERTA REPETIDA SUPRIMIDA: ${health.overdue.length} vencidas, ${health.inconsistent.length} inconsistentes.`);
    return;
  }
  await telegramAlert(buildAlert(health));
  saveLastAlert({ signature, sent_at: new Date(nowMs).toISOString(), count: affected.length });
  console.log(`EDITORIAL ALERTA TELEGRAM ENTREGADA: ${health.overdue.length} vencidas, ${health.inconsistent.length} inconsistentes.`);
}

if (require.main === module) {
  main().catch(err => { console.error(`EDITORIAL ERROR: ${err.message || err}`); process.exitCode = 1; });
}

module.exports = { keyOf, isComplete, inspectEditorial, buildAlert };
