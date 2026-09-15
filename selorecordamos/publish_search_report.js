const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const baseDir = __dirname;
const repoDir = path.join(baseDir, '..');
const sourceFile = path.join(baseDir, 'debug', 'results.json');
const reportFile = path.join(baseDir, 'search-report.json');
const reportRepoPath = 'selorecordamos/search-report.json';

function runGit(args) {
  return cp.execFileSync('git', args, { cwd: repoDir, encoding: 'utf8', stdio: 'pipe' });
}

if (!fs.existsSync(sourceFile)) {
  console.log('No hay debug/results.json; no se publica informe de búsqueda.');
  process.exit(0);
}

const source = JSON.parse(fs.readFileSync(sourceFile, 'utf8'));
const report = {
  generated_at: new Date().toISOString(),
  fetched_at: source.fetched_at || null,
  mode: source.mode || null,
  query: source.query || null,
  status: source.status || null,
  note: source.note || null,
  extracted: Number(source.extracted || 0),
  already_seen: Number(source.already_seen || 0),
  new_found: [
    ...(Array.isArray(source.candidates) ? source.candidates.map(t => ({ ...t, filter_status: 'candidate' })) : []),
    ...(Array.isArray(source.rejected) ? source.rejected.map(t => ({ ...t, filter_status: 'rejected' })) : [])
  ]
};

fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n', 'utf8');

try {
  runGit(['add', reportRepoPath]);
  const diff = cp.spawnSync('git', ['diff', '--cached', '--quiet', '--', reportRepoPath], { cwd: repoDir });
  if (diff.status === 0) {
    console.log('Informe de búsqueda sin cambios.');
    process.exit(0);
  }
  runGit(['commit', '-m', 'Update SeLoRecordamos search report', '--', reportRepoPath]);
  try {
    runGit(['push', 'origin', 'main']);
  } catch (_) {
    runGit(['pull', '--rebase', '--autostash', 'origin', 'main']);
    runGit(['push', 'origin', 'main']);
  }
  console.log('Informe de búsqueda SeLoRecordamos subido a GitHub.');
} catch (e) {
  console.error('No se pudo publicar el informe de búsqueda:', String(e.stderr || e.message || e).trim());
  process.exit(1);
}
