export const WET_THRESHOLD_MM = 0.1;

export function clamp(value, min = 0, max = 1) {
  return Math.min(max, Math.max(min, Number.isFinite(value) ? value : min));
}

export function median(values) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!clean.length) return null;
  const mid = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[mid] : (clean[mid - 1] + clean[mid]) / 2;
}

export function percentile(values, p) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!clean.length) return null;
  if (clean.length === 1) return clean[0];
  const pos = clamp(p) * (clean.length - 1);
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  if (lo === hi) return clean[lo];
  return clean[lo] + (clean[hi] - clean[lo]) * (pos - lo);
}

function weightedAverage(items, valueKey, weightKey = 'weight') {
  let numerator = 0;
  let denominator = 0;
  for (const item of items) {
    const value = item?.[valueKey];
    const weight = item?.[weightKey] ?? 1;
    if (!Number.isFinite(value) || !Number.isFinite(weight) || weight <= 0) continue;
    numerator += value * weight;
    denominator += weight;
  }
  return denominator ? numerator / denominator : null;
}

function standardDeviation(values) {
  const clean = values.filter(Number.isFinite);
  if (clean.length < 2) return clean.length ? 0 : null;
  const mean = clean.reduce((a, b) => a + b, 0) / clean.length;
  const variance = clean.reduce((sum, value) => sum + (value - mean) ** 2, 0) / clean.length;
  return Math.sqrt(variance);
}

export function aggregateEnsembleModel(hourly = {}, wetThreshold = WET_THRESHOLD_MM) {
  const time = Array.isArray(hourly.time) ? hourly.time : [];
  const memberKeys = Object.keys(hourly).filter(
    (key) => key !== 'time' && key.startsWith('precipitation') && Array.isArray(hourly[key])
  );
  if (!time.length || !memberKeys.length) return null;

  const rows = time.map((timestamp, index) => {
    const values = memberKeys.map((key) => Number(hourly[key][index])).filter(Number.isFinite);
    const wet = values.filter((value) => value >= wetThreshold).length;
    return {
      time: timestamp,
      probability: values.length ? wet / values.length : null,
      median: median(values),
      p10: percentile(values, 0.1),
      p90: percentile(values, 0.9),
      members: values.length,
    };
  });

  return { memberCount: memberKeys.length, rows };
}

export function buildConsensus({ deterministic = [], ensembles = [], nowMs = Date.now() }) {
  const allTimes = new Set();
  deterministic.forEach((model) => model.rows?.forEach((row) => allTimes.add(row.time)));
  ensembles.forEach((model) => model.rows?.forEach((row) => allTimes.add(row.time)));
  const times = [...allTimes].sort();

  const detMaps = deterministic.map((model) => ({
    ...model,
    map: new Map((model.rows || []).map((row) => [row.time, row])),
  }));
  const ensMaps = ensembles.map((model) => ({
    ...model,
    map: new Map((model.rows || []).map((row) => [row.time, row])),
  }));

  return times.map((time) => {
    const detAtTime = detMaps
      .map((model) => ({ ...model, value: Number(model.map.get(time)?.precipitation) }))
      .filter((model) => Number.isFinite(model.value));
    const ensAtTime = ensMaps
      .map((model) => {
        const row = model.map.get(time);
        return row ? { ...model, probability: row.probability, amount: row.median } : null;
      })
      .filter(Boolean);

    const detWet = weightedAverage(
      detAtTime.map((model) => ({ value: model.value >= WET_THRESHOLD_MM ? 1 : 0, weight: model.weight })),
      'value'
    );
    const ensProbability = weightedAverage(ensAtTime, 'probability');
    const probability = ensProbability == null
      ? (detWet ?? 0)
      : detWet == null
        ? ensProbability
        : 0.76 * ensProbability + 0.24 * detWet;

    const detMedian = median(detAtTime.map((model) => model.value));
    const ensAmount = weightedAverage(ensAtTime, 'amount');
    const expectedPrecipitation = ensAmount == null
      ? (detMedian ?? 0)
      : detMedian == null
        ? ensAmount
        : 0.7 * ensAmount + 0.3 * detMedian;

    const opinionVector = [
      ...detAtTime.map((model) => model.value >= WET_THRESHOLD_MM ? 1 : 0),
      ...ensAtTime.map((model) => model.probability),
    ];
    const spread = standardDeviation(opinionVector) ?? 0.5;
    const agreement = clamp(1 - spread / 0.5);
    const providerCount = detAtTime.length + ensAtTime.length;
    const providerTarget = Math.max(1, deterministic.length + ensembles.length);
    const coverage = clamp(providerCount / providerTarget);
    const horizonHours = Math.max(0, (Date.parse(time) - nowMs) / 3_600_000);
    const horizonFactor = clamp(1 - horizonHours / 96);
    const timingConfidence = clamp(0.38 + 0.32 * agreement + 0.18 * coverage + 0.12 * horizonFactor);

    return {
      time,
      probability: clamp(probability),
      expectedPrecipitation: Math.max(0, expectedPrecipitation || 0),
      agreement,
      timingConfidence,
      providerCount,
      deterministicCount: detAtTime.length,
      ensembleCount: ensAtTime.length,
    };
  });
}

function bridgeSingleHourGaps(flags) {
  const out = [...flags];
  for (let i = 1; i < flags.length - 1; i += 1) {
    if (!flags[i] && flags[i - 1] && flags[i + 1]) out[i] = true;
  }
  return out;
}

function findBoundaryWindow(points, index, direction, low = 0.22, high = 0.66) {
  const start = points[index]?.time ?? null;
  if (!start) return { earliest: null, latest: null };
  let earliestIndex = index;
  let latestIndex = index;

  if (direction === 'start') {
    while (earliestIndex > 0 && points[earliestIndex - 1].probability >= low) earliestIndex -= 1;
    while (latestIndex < points.length - 1 && points[latestIndex].probability < high) latestIndex += 1;
    latestIndex = Math.min(latestIndex, index + 2);
  } else {
    while (earliestIndex > 0 && points[earliestIndex - 1].probability >= high) earliestIndex -= 1;
    while (latestIndex < points.length - 1 && points[latestIndex + 1].probability >= low) latestIndex += 1;
    latestIndex = Math.min(points.length - 1, latestIndex + 1);
  }
  return { earliest: points[earliestIndex]?.time ?? start, latest: points[latestIndex]?.time ?? start };
}

export function detectRainEvents(points = [], { minimumProbability = 0.45 } = {}) {
  if (!points.length) return [];
  const wet = bridgeSingleHourGaps(points.map((point) =>
    point.probability >= minimumProbability || point.expectedPrecipitation >= WET_THRESHOLD_MM
  ));
  const events = [];
  let i = 0;
  while (i < points.length) {
    if (!wet[i]) { i += 1; continue; }
    const startIndex = i;
    while (i + 1 < points.length && wet[i + 1]) i += 1;
    const endIndex = i;
    const segment = points.slice(startIndex, endIndex + 1);
    const peak = segment.reduce((best, row) => row.probability > best.probability ? row : best, segment[0]);
    const totalExpected = segment.reduce((sum, row) => sum + row.expectedPrecipitation, 0);
    const meanTimingConfidence = segment.reduce((sum, row) => sum + row.timingConfidence, 0) / segment.length;
    const startWindow = findBoundaryWindow(points, startIndex, 'start');
    const endWindow = findBoundaryWindow(points, endIndex, 'end');
    const likelyEndMs = Date.parse(points[endIndex].time) + 3_600_000;

    events.push({
      start: points[startIndex].time,
      end: new Date(likelyEndMs).toISOString(),
      startWindow,
      endWindow,
      peakTime: peak.time,
      peakProbability: peak.probability,
      maxExpectedPrecipitation: Math.max(...segment.map((row) => row.expectedPrecipitation)),
      totalExpectedPrecipitation: totalExpected,
      timingConfidence: meanTimingConfidence,
      providerCount: Math.max(...segment.map((row) => row.providerCount || 0)),
    });
    i += 1;
  }
  return events;
}

export function detectQuarterHourEvents(time = [], precipitation = [], threshold = 0.03) {
  if (!Array.isArray(time) || !Array.isArray(precipitation)) return [];
  const events = [];
  let i = 0;
  while (i < time.length) {
    const value = Number(precipitation[i]);
    if (!Number.isFinite(value) || value < threshold) { i += 1; continue; }
    const startIndex = i;
    while (i + 1 < time.length && Number(precipitation[i + 1]) >= threshold) i += 1;
    const endIndex = i;
    const segment = precipitation.slice(startIndex, endIndex + 1).map(Number).filter(Number.isFinite);
    events.push({
      start: time[startIndex],
      end: new Date(Date.parse(time[endIndex]) + 15 * 60_000).toISOString(),
      max: Math.max(...segment),
      total: segment.reduce((sum, current) => sum + current, 0),
    });
    i += 1;
  }
  return events;
}

export function compactTimeline(points = [], limit = 72) {
  return points.slice(0, limit).map((row) => ({
    time: row.time,
    probability: Math.round(row.probability * 100),
    precipitation: Number(row.expectedPrecipitation.toFixed(2)),
    confidence: Math.round(row.timingConfidence * 100),
  }));
}
