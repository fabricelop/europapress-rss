const fs = require('fs');
const path = require('path');

const baseDir = __dirname;
const resultsFile = path.join(baseDir, 'debug', 'results.json');
const outboxFile = path.join(baseDir, 'telegram-outbox.json');
const candidatesDir = path.join(baseDir, 'candidates');

const readJson = (file, fallback) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return fallback; } };
const writeJson = (file, data) => fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');

const result = readJson(resultsFile, null);
if (!result) process.exit(0);

// Decisión editorial vigente: la propia consulta de X ya está restringida a las
// seis expresiones acordadas. No se aplica ningún filtro semántico posterior.
// Este paso solo conserva candidatos pendientes entre barridos.
const outbox = readJson(outboxFile, { generated_at: result.fetched_at, candidates: [] });
const pendingMap = new Map((outbox.candidates || []).map(c => [String(c.id), c]));

for (const c of result.candidates || []) {
  pendingMap.set(String(c.id), c);
  writeJson(path.join(candidatesDir, `${c.id}.json`), c);
}

outbox.generated_at = result.fetched_at;
outbox.candidates = [...pendingMap.values()].slice(-200);
writeJson(outboxFile, outbox);
