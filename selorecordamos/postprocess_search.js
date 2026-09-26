const fs = require('fs');
const path = require('path');

const baseDir = __dirname;
const resultsFile = path.join(baseDir, 'debug', 'results.json');
const outboxFile = path.join(baseDir, 'telegram-outbox.json');
const candidatesDir = path.join(baseDir, 'candidates');

const readJson = (file, fallback) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return fallback; } };
const writeJson = (file, data) => fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
const normalizeText = (text) => String(text || '').toLocaleLowerCase('es-ES').replace(/\s+/g, ' ').trim();
const rejectReason = (text) => normalizeText(text).includes('me recuerden por') ? 'excluded_phrase_me_recuerden_por' : null;

const result = readJson(resultsFile, null);
if (!result) process.exit(0);

// Defensa adicional: aunque la búsqueda ya aplica el descarte, este paso vuelve a
// filtrar pendientes y resultados para evitar que candidatos antiguos o stale reaparezcan.
const outbox = readJson(outboxFile, { generated_at: result.fetched_at, candidates: [] });
const pendingMap = new Map(
  (outbox.candidates || [])
    .filter(c => !rejectReason(c && c.text))
    .map(c => [String(c.id), c])
);

for (const c of result.candidates || []) {
  if (rejectReason(c && c.text)) continue;
  pendingMap.set(String(c.id), c);
  writeJson(path.join(candidatesDir, `${c.id}.json`), c);
}

outbox.generated_at = result.fetched_at;
outbox.candidates = [...pendingMap.values()].slice(-200);
writeJson(outboxFile, outbox);
