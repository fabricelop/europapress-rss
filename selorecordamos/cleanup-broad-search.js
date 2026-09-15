const fs = require('fs');
const path = require('path');

const baseDir = __dirname;
const runtimeDir = path.join(baseDir, 'runtime');
const candidatesDir = path.join(baseDir, 'candidates');
const seenFile = path.join(runtimeDir, 'seen.json');
const outboxFile = path.join(baseDir, 'telegram-outbox.json');
const badRun = '2026-09-15T08:36:02.039Z';

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (_) { return fallback; }
}
function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

let seenRemoved = 0;
const seen = readJson(seenFile, {});
for (const [id, info] of Object.entries(seen)) {
  if (info && info.first_seen_at === badRun) {
    delete seen[id];
    seenRemoved++;
  }
}
writeJson(seenFile, seen);

let filesRemoved = 0;
if (fs.existsSync(candidatesDir)) {
  for (const file of fs.readdirSync(candidatesDir).filter(x => x.endsWith('.json'))) {
    const full = path.join(candidatesDir, file);
    const c = readJson(full, null);
    if (c && c.first_seen_at === badRun) {
      fs.unlinkSync(full);
      filesRemoved++;
    }
  }
}

const outbox = readJson(outboxFile, { generated_at: null, candidates: [] });
const before = Array.isArray(outbox.candidates) ? outbox.candidates.length : 0;
outbox.candidates = (outbox.candidates || []).filter(c => c.first_seen_at !== badRun);
const outboxRemoved = before - outbox.candidates.length;
writeJson(outboxFile, outbox);

console.log(JSON.stringify({
  bad_run: badRun,
  seen_removed: seenRemoved,
  candidate_files_removed: filesRemoved,
  outbox_candidates_removed: outboxRemoved,
  status: 'clean'
}, null, 2));
