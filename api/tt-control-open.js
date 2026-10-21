import crypto from "crypto";

async function tg(token, method, body) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST", headers: {"content-type":"application/json"}, body: JSON.stringify(body)
  });
  return r.json();
}

export default async function handler(req, res) {
  const messageId = String(req.query.m || "");
  const sig = String(req.query.s || "");
  const secret = process.env.TELEGRAM_WEBHOOK_SECRET || "";
  const token = process.env.TELEGRAM_BOT_TOKEN || "";
  const chatId = process.env.TELEGRAM_CHAT_ID || "";
  if (!messageId || !sig || !secret || !token || !chatId) return res.redirect(302, "https://tt-control.fabricelop.workers.dev/?view=READY");
  const expected = crypto.createHmac("sha256", secret).update(messageId).digest("hex");
  try {
    if (crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) {
      await tg(token, "deleteMessage", {chat_id: chatId, message_id: Number(messageId)});
    }
  } catch (_) {}
  return res.redirect(302, "https://tt-control.fabricelop.workers.dev/?view=READY");
}
