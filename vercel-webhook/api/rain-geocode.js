function send(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=86400, stale-while-revalidate=604800');
  res.end(JSON.stringify(body));
}

export default async function handler(req, res) {
  if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' });
  const q = String(req.query?.q || '').trim();
  if (q.length < 2 || q.length > 120) return send(res, 400, { error: 'invalid_query' });
  const params = new URLSearchParams({ name: q, count: '8', language: 'es', format: 'json' });
  try {
    const response = await fetch(`https://geocoding-api.open-meteo.com/v1/search?${params}`, { signal: AbortSignal.timeout(6000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    const results = (data.results || []).map((item) => ({
      id: item.id,
      name: item.name,
      admin1: item.admin1 || null,
      country: item.country || null,
      latitude: item.latitude,
      longitude: item.longitude,
      timezone: item.timezone || null,
    }));
    return send(res, 200, { results });
  } catch (error) {
    return send(res, 502, { error: 'geocoding_unavailable', message: String(error?.message || error) });
  }
}
