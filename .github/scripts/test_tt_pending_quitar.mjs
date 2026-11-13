// Validate both web variants expose a real, revision-scoped Quitar action.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
for (const relative of ['docs/ttactualidad/index.html', 'pilot/ttactualidad-live/index.html']) {
  const html = fs.readFileSync(path.join(root, relative), 'utf8');
  const match = html.match(/<script>([\s\S]*?)<\/script>/);
  assert.ok(match, `${relative} requires an inline script`);
  new vm.Script(match[1], { filename: relative });
  assert.ok(html.includes("command('Quitar','retire')"), `${relative}: missing button`);
  assert.ok(html.includes("state.tab==='pendientes'&&x._kind==='tr'"),
    `${relative}: button must be restricted to Pending trends`);
  assert.ok(html.includes("'trends/pending-retirements.json':'pendingRetirements'"),
    `${relative}: missing persisted removal ledger`);
  assert.ok(html.includes("!x._retiredNow"),
    `${relative}: stale pending card would reappear on refresh`);
  assert.ok(html.includes("op.decision==='retire'"),
    `${relative}: missing GitHub result confirmation`);
}
const pages = fs.readFileSync(path.join(root, 'docs/ttactualidad/index.html'), 'utf8');
assert.ok(pages.includes("'### Revisión del elemento'"),
  'GitHub Issue must carry exact editorial revision');
assert.ok(pages.includes("¿Quitar esta tendencia de Pendientes?"),
  'V1 requires explicit confirmation');
const worker = fs.readFileSync(path.join(root, 'pilot/ttactualidad-live/worker.js'), 'utf8');
assert.ok(worker.includes("'retire'"));
console.log('TT_PENDING_QUITAR_WEB_OK');
