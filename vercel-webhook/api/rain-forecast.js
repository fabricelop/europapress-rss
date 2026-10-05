import {
  aggregateEnsembleModel,
  buildConsensus,
  compactTimeline,
  detectQuarterHourEvents,
  detectRainEvents,
} from '../lib/rain-forecast-core.js';

const DET_MODELS = [
  { id: 'ecmwf_ifs025', label: 'ECMWF IFS', weight: 1.25 },
  { id: 'ecmwf_aifs025', label: 'ECMWF AIFS', weight: 1.05 },
  { id: 'icon_seamless', label: 'DWD ICON', weight: 1.1 },
  { id: 'gfs_seamless', label: 'NOAA GFS', weight: 0.9 },
  { id: 'meteofrance_seamless', label: 'Météo-France', weight: 1.0 },
  { id: 'gem_seamless', label: 'CMC GEM', weight: 0.75 },
];

const ENS_MODELS = [
  { id: 'ecmwf_ifs025_ensemble', label: 'ECMWF ENS', weight: 1.25 },
  { id: 'ecmwf_aifs025_ensemble', label: 'ECMWF AIFS ENS', weight: 1.0 },
  { id: 'dwd_icon_eu_eps', label: 'ICON-EU EPS', weight: 1.1 },
  { id: 'ncep_gefs025', label: 'NOAA GEFS', weight: 0.9 },
  { id: 'ukmo_global_ensemble_20km', label: 'UKMO MOGREPS-G', weight: 0.95 },
  { id: 'cmc_gem_geps', label: 'CMC GEPS', weight: 0.75 },
];

const timeoutMs = 8_500;

function json(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
  res.end(JSON.stringify(body));
}

function numeric(value, fallback = null) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function validCoordinates(lat, lon) {
  return Number.isFinite(lat) && Number.isFinite(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
}

async function fetchJson(url, timeout = timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { 'User-Agent': 'RainETA/0.1 (+personal weather nowcasting project)' },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function isoTime(value) {
  if (Number.isFinite(Number(value))) return new Date(Number(value) * 1000).toISOString();
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : String(value);
}

function normalizeHourlyTimes(hourly = {}) {
  if (!Array.isArray(hourly.time)) return hourly;
  return { ...hourly, time: hourly.time.map(isoTime) };
}

async function fetchDeterministic(model, lat, lon) {
  const params = new URLSearchParams({
    latitude: String(lat),
    longitude: String(lon),
    hourly: 'precipitation',
    forecast_days: '4',
    timeformat: 'unixtime',
    timezone: 'GMT',
    models: model.id,
  });
  const url = `https://api.open-meteo.com/v1/forecast?${params}`;
  const payload = await fetchJson(url);
  const hourly = normalizeHourlyTimes(payload.hourly || {});
  const rows = (hourly.time || []).map((time, index) => ({
    time,
    precipitation: numeric(hourly.precipitation?.[index], 0),
  }));
  return {
    id: model.id,
    label: model.label,
    weight: model.weight,
    rows,
    timezone: payload.timezone,
    elevation: payload.elevation,
  };
}

async function fetchEnsemble(model, lat, lon) {
  const params = new URLSearchParams({
    latitude: String(lat),
    longitude: String(lon),
    hourly: 'precipitation',
    forecast_days: '4',
    timeformat: 'unixtime',
    timezone: 'GMT',
    models: model.id,
    temporal_resolution: 'hourly',
  });
  const url = `https://ensemble-api.open-meteo.com/v1/ensemble?${params}`;
  const payload = await fetchJson(url);
  const aggregate = aggregateEnsembleModel(normalizeHourlyTimes(payload.hourly || {}));
  if (!aggregate) throw new Error('Ensemble without precipitation members');
  return {
    id: model.id,
    label: model.label,
    weight: model.weight,
    memberCount: aggregate.memberCount,
    rows: aggregate.rows,
  };
}

async function fetchQuarterHourGuidance(lat, lon) {
  const params = new URLSearchParams({
    latitude: String(lat),
    longitude: String(lon),
    current: 'precipitation,rain,showers',
    minutely_15: 'precipitation',
    forecast_minutely_15: '32',
    timeformat: 'unixtime',
    timezone: 'GMT',
  });
  const payload = await fetchJson(`https://api.open-meteo.com/v1/forecast?${params}`, 7_500);
  const minutely = payload.minutely_15 || {};
  const times = (minutely.time || []).map(isoTime);
  const precipitation = (minutely.precipitation || []).map(value => numeric(value, 0));
  return {
    current: {
      time: payload.current?.time ? isoTime(payload.current.time) : null,
      precipitation: numeric(payload.current?.precipitation, null),
      rain: numeric(payload.current?.rain, null),
      showers: numeric(payload.current?.showers, null),
    },
    time: times,
    precipitation,
    events: detectQuarterHourEvents(times, precipitation),
    note: 'Guía a 15 min del modelo; puede ser interpolada según la cobertura del modelo y no sustituye al radar.',
  };
}

async function fetchRadarMetadata() {
  const payload = await fetchJson('https://api.rainviewer.com/public/weather-maps.json', 5_000);
  const frames = (payload.radar?.past || []).slice(-12).map((frame) => ({
    time: Number(frame.time),
    path: frame.path,
  }));
  return {
    provider: 'RainViewer',
    host: payload.host,
    generated: Number(payload.generated) || null,
    frames,
    attribution: 'Weather radar data by RainViewer',
  };
}

function statusFromResults(definitions, settled) {
  return definitions.map((model, index) => {
    const result = settled[index];
    return {
      id: model.id,
      label: model.label,
      weight: model.weight,
      ok: result.status === 'fulfilled',
      error: result.status === 'rejected' ? String(result.reason?.message || result.reason || 'error') : null,
      members: result.status === 'fulfilled' ? result.value.memberCount ?? null : null,
    };
  });
}

function sourceHealth(detStatus, ensStatus, radar, guidance) {
  const available = [...detStatus, ...ensStatus].filter((item) => item.ok).length + (radar ? 1 : 0) + (guidance ? 1 : 0);
  const total = detStatus.length + ensStatus.length + 2;
  return { available, total, ratio: total ? available / total : 0 };
}

export default async function handler(req, res) {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return json(res, 405, { error: 'method_not_allowed' });
  }

  const lat = numeric(req.query?.lat);
  const lon = numeric(req.query?.lon);
  if (!validCoordinates(lat, lon)) {
    return json(res, 400, { error: 'invalid_coordinates', message: 'lat/lon requeridos y válidos.' });
  }

  const nowMs = Date.now();
  const [detSettled, ensSettled, guidanceSettled, radarSettled] = await Promise.all([
    Promise.allSettled(DET_MODELS.map((model) => fetchDeterministic(model, lat, lon))),
    Promise.allSettled(ENS_MODELS.map((model) => fetchEnsemble(model, lat, lon))),
    Promise.allSettled([fetchQuarterHourGuidance(lat, lon)]),
    Promise.allSettled([fetchRadarMetadata()]),
  ]);

  const deterministic = detSettled.filter((item) => item.status === 'fulfilled').map((item) => item.value);
  const ensembles = ensSettled.filter((item) => item.status === 'fulfilled').map((item) => item.value);
  const guidance = guidanceSettled[0]?.status === 'fulfilled' ? guidanceSettled[0].value : null;
  const radar = radarSettled[0]?.status === 'fulfilled' ? radarSettled[0].value : null;
  const detStatus = statusFromResults(DET_MODELS, detSettled);
  const ensStatus = statusFromResults(ENS_MODELS, ensSettled);

  if (!deterministic.length && !ensembles.length && !guidance) {
    return json(res, 503, {
      error: 'forecast_sources_unavailable',
      generatedAt: new Date(nowMs).toISOString(),
      sources: { deterministic: detStatus, ensembles: ensStatus, radar: Boolean(radar) },
    });
  }

  const consensusRaw = buildConsensus({ deterministic, ensembles, nowMs });
  const horizonEnd = nowMs + 72 * 3_600_000;
  const consensus = consensusRaw.filter((row) => {
    const timestamp = Date.parse(row.time);
    return timestamp >= nowMs - 45 * 60_000 && timestamp <= horizonEnd;
  });
  const events = detectRainEvents(consensus).filter((event) => Date.parse(event.end) > nowMs);
  const nextEvent = events[0] || null;
  const health = sourceHealth(detStatus, ensStatus, radar, guidance);

  return json(res, 200, {
    generatedAt: new Date(nowMs).toISOString(),
    location: { lat, lon },
    current: guidance?.current || null,
    nextEvent,
    events: events.slice(0, 8),
    timeline: compactTimeline(consensus, 73),
    shortTerm: guidance ? {
      intervalMinutes: 15,
      time: guidance.time,
      precipitation: guidance.precipitation,
      events: guidance.events,
      note: guidance.note,
    } : null,
    radar,
    sources: {
      health,
      deterministic: detStatus,
      ensembles: ensStatus,
      methodology: {
        horizonHours: 72,
        wetThresholdMmPerHour: 0.1,
        consensus: 'La probabilidad combina ensembles y acuerdo de modelos deterministas; los ensembles pesan más. Los modelos se ponderan por familia, no por número de miembros.',
        caveat: 'La precisión temporal disminuye con el horizonte. El radar real se usa como observación; el nowcasting radar propio se integra por separado para 0–2 h.',
      },
    },
  });
}
