import test from 'node:test';
import assert from 'node:assert/strict';
import {checkAndDispatch} from '../src/index.mjs';

const now = new Date('2026-11-19T08:30:00Z');
const token = 'ghp_TEST_ONLY_NEVER_USE_AS_CREDENTIAL_123';
const env = {GITHUB_DISPATCH_TOKEN: token};

function json(data, status = 200) {
  return {ok: status >= 200 && status < 300, status, json: async () => data};
}
function setup({age = 30, runs = [], dispatch = 204, summaryStatus = 200,
                runsStatus = 200} = {}) {
  const calls = [];
  const logs = [];
  const fetcher = async (url, opts = {}) => {
    calls.push({url, opts});
    if (url.includes('raw.githubusercontent.com')) {
      return json({kind: 'independent_radar_summary', project: 'ttittulares-v2',
        observed_at: new Date(now.getTime() - age * 60_000).toISOString()}, summaryStatus);
    }
    if (url.endsWith('/dispatches')) return {ok: dispatch === 204, status: dispatch};
    return json({workflow_runs: runs}, runsStatus);
  };
  const logger = {log: (...args) => logs.push(args),
    warn: (...args) => logs.push(args)};
  return {calls, logs, fetcher, logger};
}

test('fresh radar does not use GitHub API or dispatch', async () => {
  const fake = setup({age: 12});
  const result = await checkAndDispatch(env, {...fake, now});
  assert.equal(result.state, 'fresh');
  assert.equal(fake.calls.length, 1);
});

test('stale radar dispatches only fixed workflow on main', async () => {
  const fake = setup();
  const result = await checkAndDispatch(env, {...fake, now});
  assert.equal(result.dispatched, true);
  assert.equal(fake.calls.length, 3);
  assert.match(fake.calls[2].url, /ttittulares-v2-radar-clock\.yml\/dispatches$/);
  assert.equal(fake.calls[2].opts.method, 'POST');
  assert.deepEqual(JSON.parse(fake.calls[2].opts.body), {ref: 'main'});
  assert.equal(fake.calls[2].opts.headers.Authorization, `Bearer ${token}`);
  assert.ok(!JSON.stringify(fake.logs).includes(token));
});

test('recent workflow run prevents another dispatch', async () => {
  const fake = setup({runs: [{head_branch: 'main', status: 'completed',
    created_at: new Date(now.getTime() - 2 * 60_000).toISOString()}]});
  const result = await checkAndDispatch(env, {...fake, now});
  assert.equal(result.state, 'run_already_scheduled');
  assert.equal(fake.calls.length, 2);
});

test('active workflow run prevents dispatch during slow processing', async () => {
  const fake = setup({runs: [{head_branch: 'main', status: 'in_progress',
    created_at: new Date(now.getTime() - 22 * 60_000).toISOString()}]});
  const result = await checkAndDispatch(env, {...fake, now});
  assert.equal(result.dispatched, false);
});

test('old finished workflow run allows recovery', async () => {
  const fake = setup({runs: [{head_branch: 'main', status: 'completed',
    created_at: new Date(now.getTime() - 35 * 60_000).toISOString()}]});
  assert.equal((await checkAndDispatch(env, {...fake, now})).state, 'dispatched');
});

test('missing token cannot access GitHub', async () => {
  const fake = setup();
  await assert.rejects(checkAndDispatch({}, {...fake, now}), /SECRET_MISSING/);
  assert.equal(fake.calls.length, 0);
});

test('invalid summary blocks all dispatches', async () => {
  const fake = setup({summaryStatus: 503});
  await assert.rejects(checkAndDispatch(env, {...fake, now}), /SUMMARY_UNAVAILABLE/);
  assert.equal(fake.calls.length, 1);
});

test('GitHub access denial blocks dispatches', async () => {
  const fake = setup({runsStatus: 403});
  await assert.rejects(checkAndDispatch(env, {...fake, now}), /STATUS_UNAVAILABLE/);
  assert.equal(fake.calls.length, 2);
});

test('GitHub must acknowledge workflow_dispatch with status 204', async () => {
  const fake = setup({dispatch: 403});
  await assert.rejects(checkAndDispatch(env, {...fake, now}), /NOT_ACCEPTED/);
});
