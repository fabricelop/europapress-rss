import test from 'node:test';
import assert from 'node:assert/strict';
import {trackSiteEvent, METRIC_EVENTS} from './analytics-events.mjs';

test('safe anonymous named event without payload', () => {
  const calls=[]; assert(trackSiteEvent(METRIC_EVENTS.feedback, {}, {track:(...x)=>calls.push(x)}));
  assert.deepEqual(calls, [[METRIC_EVENTS.feedback]]);
});
test('top 30 card opens track public rank, never entered text or identities', () => {
  const calls=[]; trackSiteEvent(METRIC_EVENTS.expand, {rank:12,email:'private@example.com',search:'secret'}, {track:(...x)=>calls.push(x)});
  assert.deepEqual(calls, [[METRIC_EVENTS.expand, {rank:12}]]);
});
test('invalid event names and non-Top30 rank are dropped safely', () => {
  const calls=[]; const tracker={track:(...x)=>calls.push(x)};
  assert.equal(trackSiteEvent('Search query: password', {}, tracker), false);
  assert(trackSiteEvent(METRIC_EVENTS.expand, {rank:0}, tracker));
  assert.deepEqual(calls, [[METRIC_EVENTS.expand]]);
});
test('never break the website when blocked or not installed', () => {
  assert.equal(trackSiteEvent(METRIC_EVENTS.search, {}, null), false);
  assert.equal(trackSiteEvent(METRIC_EVENTS.search, {}, {track:()=>{throw Error('blocked')}}), false);
});
