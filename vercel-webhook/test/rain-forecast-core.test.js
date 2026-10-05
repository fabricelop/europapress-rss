import test from 'node:test';
import assert from 'node:assert/strict';
import {
  aggregateEnsembleModel,
  buildConsensus,
  detectQuarterHourEvents,
  detectRainEvents,
  median,
  percentile,
} from '../lib/rain-forecast-core.js';

test('median and percentile handle simple samples', () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([1, 3]), 2);
  assert.equal(percentile([0, 10], 0.5), 5);
});

test('aggregateEnsembleModel derives wet probability and quantiles', () => {
  const result = aggregateEnsembleModel({
    time: ['2026-10-06T00:00:00.000Z'],
    precipitation_member00: [0],
    precipitation_member01: [0.2],
    precipitation_member02: [1.0],
    precipitation_member03: [0.05],
  });
  assert.equal(result.memberCount, 4);
  assert.equal(result.rows[0].probability, 0.5);
  assert.equal(result.rows[0].median, 0.125);
});

test('buildConsensus weights ensemble probability more than deterministic vote', () => {
  const time = '2026-10-06T12:00:00.000Z';
  const points = buildConsensus({
    nowMs: Date.parse('2026-10-06T00:00:00Z'),
    deterministic: [
      { weight: 1, rows: [{ time, precipitation: 0 }] },
      { weight: 1, rows: [{ time, precipitation: 0.4 }] },
    ],
    ensembles: [
      { weight: 1, rows: [{ time, probability: 0.8, median: 0.3 }] },
    ],
  });
  assert.equal(points.length, 1);
  assert.ok(points[0].probability > 0.65 && points[0].probability < 0.75);
});

test('detectRainEvents bridges a single dry hour and returns one event', () => {
  const base = Date.parse('2026-10-06T10:00:00Z');
  const probabilities = [0.1, 0.7, 0.3, 0.75, 0.1];
  const points = probabilities.map((probability, index) => ({
    time: new Date(base + index * 3600_000).toISOString(),
    probability,
    expectedPrecipitation: probability >= 0.45 ? 0.4 : 0,
    timingConfidence: 0.8,
    providerCount: 8,
  }));
  const events = detectRainEvents(points);
  assert.equal(events.length, 1);
  assert.equal(events[0].start, points[1].time);
  assert.equal(events[0].end, new Date(base + 4 * 3600_000).toISOString());
});

test('detectQuarterHourEvents returns precise 15-minute window', () => {
  const times = [0, 1, 2, 3].map((i) => new Date(Date.parse('2026-10-06T10:00:00Z') + i * 15 * 60_000).toISOString());
  const events = detectQuarterHourEvents(times, [0, 0.04, 0.2, 0]);
  assert.equal(events.length, 1);
  assert.equal(events[0].start, times[1]);
  assert.equal(events[0].end, times[3]);
});
