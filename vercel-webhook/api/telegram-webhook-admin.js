export default async function handler(req, res) {
  const expected = process.env.TELEGRAM_WEBHOOK_SECRET;
  const supplied = req.headers["x-tt-admin-secret"];
  if (!expected || supplied !== expected) return res.status(401).json({ ok: false });

  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) return res.status(500).json({ ok: false, error: "TELEGRAM_BOT_TOKEN missing" });

  const base = `https://api.telegram.org/bot${token}`;
  if (req.method === "GET") {
    const r = await fetch(base + "/getWebhookInfo");
    const data = await r.json();
    if (data?.result?.url) {
      try { data.result.url = new URL(data.result.url).origin + new URL(data.result.url).pathname; } catch {}
    }
    return res.status(r.ok ? 200 : 502).json(data);
  }
  if (req.method === "POST") {
    const host = req.headers["x-forwarded-host"] || req.headers.host;
    const proto = req.headers["x-forwarded-proto"] || "https";
    const url = `${proto}://${host}/api/telegram-webhook`;
    const r = await fetch(base + "/setWebhook", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ url, secret_token: expected, allowed_updates: ["message", "callback_query"], drop_pending_updates: false })
    });
    const data = await r.json();
    return res.status(r.ok ? 200 : 502).json({ ...data, webhook_url: url });
  }
  return res.status(405).json({ ok: false });
}
