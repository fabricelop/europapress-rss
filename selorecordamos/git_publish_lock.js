// Lock used by the two SeLoRecordamos Git publishers.
// Never removes another live publisher's lock; stale owners are recovered.
const fs = require('fs');
const path = require('path');
const lockFile = path.join(__dirname, 'runtime', 'git-publish.lock');
const sleepCell = new Int32Array(new SharedArrayBuffer(4));

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e && e.code === 'EPERM'; }
}

module.exports = function withGitPublishLock(work) {
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  let acquired = false;
  for (let i = 0; i < 120; i++) { // 30s max wait
    try {
      const fd = fs.openSync(lockFile, 'wx');
      try { fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, started: new Date().toISOString() })); }
      finally { fs.closeSync(fd); }
      acquired = true;
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let owner = null;
      try { owner = JSON.parse(fs.readFileSync(lockFile, 'utf8')); } catch (_) {}
      if (!owner || !alive(owner.pid)) {
        try { fs.unlinkSync(lockFile); } catch (_) {}
        continue;
      }
      Atomics.wait(sleepCell, 0, 0, 250);
    }
  }
  if (!acquired) throw new Error('Otra publicacion Git sigue activa; reintentar en la siguiente ejecucion.');
  try {
    return work();
  } finally {
    try {
      const owner = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
      if (owner.pid === process.pid) fs.unlinkSync(lockFile);
    } catch (_) {}
  }
};
