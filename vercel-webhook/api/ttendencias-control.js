import crypto from "node:crypto";
import webpush from "web-push";
import sharp from "sharp";
import {
  annotateExplainedCopyState,
  buildCopyRecord,
  explanationCopyIdentity,
} from "../lib/ttendencias-copy-state.js";
import {
  annotateRemateRatings,
  buildRemateRatingRecord,
  remateRatingIdentity,
} from "../lib/ttendencias-remate-ratings.js";

const REPO = process.env.GITHUB_REPO || "fabricelop/europapress-rss";
const BRANCH = process.env.GITHUB_BRANCH || "main";
const RECENT = "trends/recent.json";
const REQUESTS = "trends/requests.json";
const EXPLAINED = "trends/telegram-manual-explained.json";
const EXPLAINED_COPY_STATE = "trends/explained-copy-state.json";
const REMATE_RATINGS = "trends/remate-ratings.json";
const PREPARED = "trends/prepared.json";
const HEALTH = "trends/health-status.json";
const EDITORIAL_CONFIG = "trends/editorial-config.json";
const EDITORIAL_QUEUE = "trends/editorial-queue.json";
const PUSH_STATE = "trends/push-state.json";
const REFRESH_TRIGGER = "trends/refresh-trigger.txt";

function b64decode(s) {
  return Buffer.from(String(s || "").replace(/\n/g, ""), "base64").toString("utf8");
}
function b64encode(s) {
  return Buffer.from(s, "utf8").toString("base64");
}
function norm(v) {
  return String(v || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase("es-ES").replace(/\s+/g, " ").trim();
}
function explanationNames(item) {
  const values = [item?.name, ...(Array.isArray(item?.trend_names) ? item.trend_names : [])];
  for (const ctx of (Array.isArray(item?.trend_context) ? item.trend_context : [])) values.push(ctx?.name);
  return [...new Set(values.map(x => String(x || "").trim()).filter(Boolean))];
}
function reconcileExplainedView(explainedDoc, requestsDoc) {
  const doc = {
    ...(explainedDoc || {}),
    items: (explainedDoc?.items || []).map(row => ({ ...row })),
  };
  const latestById = new Map();
  const latestByName = new Map();
  for (const req of (requestsDoc?.requests || [])) {
    if (String(req?.status || "") !== "explained" || !String(req?.explanation || "").trim()) continue;
    const id = String(req?.id || "").trim();
    const name = norm(req?.name);
    const choose = prev => {
      if (!prev) return req;
      const rr = Number(req?.revision || 0), pr = Number(prev?.revision || 0);
      if (rr !== pr) return rr > pr ? req : prev;
      return String(req?.explained_at || req?.requested_at || "") > String(prev?.explained_at || prev?.requested_at || "") ? req : prev;
    };
    if (id) latestById.set(id, choose(latestById.get(id)));
    if (name) latestByName.set(name, choose(latestByName.get(name)));
  }
  doc.items = doc.items.map(row => {
    const req = latestById.get(String(row?.id || "").trim()) || latestByName.get(norm(row?.name));
    if (!req) return row;
    const newerRevision = Number(req?.revision || 0) > Number(row?.revision || 0);
    const completedAfterRewrite = Boolean(row?.rewrite_pending) &&
      String(req?.explained_at || req?.requested_at || "") >= String(row?.rewrite_requested_at || "");
    if (!newerRevision && !completedAfterRewrite) return row;
    const merged = { ...row, ...req };
    delete merged.rewrite_pending;
    delete merged.rewrite_requested_at;
    delete merged.rewrite_request_version;
    delete merged.rewrite_instruction;
    delete merged.reexplain;
    return merged;
  });
  return doc;
}

function authToken(req) {
  const h = String(req.headers.authorization || "");
  return h.startsWith("Bearer ") ? h.slice(7).trim() : "";
}
const CONTROL_TOKEN_HASHES = [
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "e6dc803e75f1bad2c6caee93b1a7fce3df540f70c8313a7e08a998506d0dcb61"
];
function authorized(req) {
  const got = authToken(req);
  if (!got) return false;
  const expected = process.env.TTENDENCIAS_CONTROL_TOKEN || "";
  if (expected && got === expected) return true;
  const digest = Buffer.from(crypto.createHash("sha256").update(got).digest("hex"));
  return CONTROL_TOKEN_HASHES.some(hash => crypto.timingSafeEqual(digest, Buffer.from(hash)));
}
async function authorizedGitHubWorkflow(req) {
  const got = authToken(req);
  if (!got) return false;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${got}`,
        "x-github-api-version": "2022-11-28",
        "user-agent": "ttendencias-push-trigger",
      },
    });
    if (!r.ok) return false;
    const repo = await r.json();
    return String(repo.full_name || "") === REPO && Boolean(repo.permissions?.push);
  } catch (_) {
    return false;
  }
}
async function gh(path, options = {}) {
  const token = process.env.GITHUB_TOKEN;
  const r = await fetch(`https://api.github.com/repos/${REPO}/${path}`, {
    ...options,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": "2022-11-28",
      "user-agent": "ttendencias-control",
      ...(options.headers || {}),
    },
  });
  return r;
}
async function readJson(path) {
  const r = await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
  if (!r.ok) throw new Error(`GitHub GET ${path}: ${r.status} ${await r.text()}`);
  const file = await r.json();
  return { doc: JSON.parse(b64decode(file.content) || "{}"), sha: file.sha };
}
async function readPublicJson(path) {
  const clean = String(path || "").split("/").map(encodeURIComponent).join("/");
  const url = `https://raw.githubusercontent.com/${REPO}/${encodeURIComponent(BRANCH)}/${clean}?t=${Date.now()}`;
  const r = await fetch(url, { cache: "no-store", headers: { "user-agent": "ttendencias-web-read" } });
  if (!r.ok) throw new Error(`GitHub RAW ${path}: ${r.status}`);
  const raw = await r.text();
  if (!raw.trim()) throw new Error(`GitHub RAW ${path}: contenido vacío`);
  return { doc: JSON.parse(raw), sha: null, source: "raw" };
}

async function readText(path) {
  const r = await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
  if (r.status === 404) return { text: "", sha: null };
  if (!r.ok) throw new Error(`GitHub GET ${path}: ${r.status} ${await r.text()}`);
  const file = await r.json();
  return { text: b64decode(file.content) || "", sha: file.sha };
}
async function writeText(path, message, text) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    const current = await readText(path);
    const body = {
      message,
      content: b64encode(String(text)),
      branch: BRANCH,
    };
    if (current.sha) body.sha = current.sha;
    const r = await gh(`contents/${path}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (r.ok) return true;
    if (![409, 422].includes(r.status)) throw new Error(`GitHub PUT ${path}: ${r.status} ${await r.text()}`);
    await new Promise(resolve => setTimeout(resolve, attempt * 150));
  }
  throw new Error(`Conflicto persistente actualizando ${path}`);
}
async function mutateJson(path, message, mutator) {
  for (let attempt = 1; attempt <= 5; attempt++) {
    const { doc, sha } = await readJson(path);
    const before = JSON.stringify(doc);
    const next = await mutator(doc);
    if (JSON.stringify(next) === before) return next;
    const r = await gh(`contents/${path}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        message,
        content: b64encode(JSON.stringify(next, null, 2) + "\n"),
        sha,
        branch: BRANCH,
      }),
    });
    if (r.ok) return next;
    if (![409, 422].includes(r.status)) throw new Error(`GitHub PUT ${path}: ${r.status} ${await r.text()}`);
    await new Promise(resolve => setTimeout(resolve, attempt * 150));
  }
  throw new Error(`Conflicto persistente actualizando ${path}`);
}

async function syncEditorialQueue() {
  const [{ doc: requests }, { doc: recent }] = await Promise.all([
    readJson(REQUESTS),
    readJson(RECENT),
  ]);
  const top10 = new Set((recent.items || []).slice(0,10).map(x => norm(x.name)).filter(Boolean));
  const active = (requests.requests || [])
    .filter(req => {
      const status = String(req.status || "");
      if (["preparing", "update"].includes(status)) return true;
      return status === "problematic" && top10.has(norm(req.name));
    })
    .map(req => ({
      id: req.id,
      name: req.name,
      rank: req.rank,
      status: req.status,
      requested_at: req.requested_at,
      revision: Number(req.revision || 0),
      rewrite_instruction: req.rewrite_instruction || req.rewrite_request || "",
      with_image: req.with_image !== false,
      disable_ai_image: Boolean(req.disable_ai_image),
      image_strategy: req.image_strategy || null,
      selected_tweet_image: req.selected_tweet_image || null,
      task: "explain",
      batch_id: req.batch_id || null,
      requested_together: Array.isArray(req.requested_together) ? req.requested_together : [req.name].filter(Boolean),
      captured_with: Array.isArray(req.captured_with) ? req.captured_with : [],
      auto_queued: Boolean(req.auto_queued),
      anticipated: Boolean(req.anticipated),
      anticipated_at: req.anticipated_at || null,
      anticipated_best_rank: req.anticipated_best_rank || null,
      anticipated_social_source_count: req.anticipated_social_source_count || 0,
      anticipated_news_source_count: req.anticipated_news_source_count || 0,
      anticipated_news_title: req.anticipated_news_title || "",
      anticipated_entered_top10_at: req.anticipated_entered_top10_at || null,
      tremending_origin: Boolean(req.tremending_origin),
      tremending_id: req.tremending_id || null,
      article_title: req.article_title || null,
      source_url: req.source_url || null,
      selected_tweet: req.selected_tweet || null,
    }))
    .sort((a, b) => String(a.requested_at || "").localeCompare(String(b.requested_at || "")));
  const now = new Date().toISOString();
  await mutateJson(EDITORIAL_QUEUE, "Sincronizar cola editorial TTendencias desde web", () => ({
    project: "TTendencias",
    updated_at: now,
    count: active.length,
    items: active,
  }));
  return active;
}

function b64url(value) {
  return Buffer.from(value).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function pushMasterSecret() {
  const secret = process.env.TTENDENCIAS_PUSH_SECRET || process.env.GITHUB_TOKEN || process.env.TTENDENCIAS_CONTROL_TOKEN || "";
  if (!secret) throw new Error("No hay secreto de servidor disponible para Web Push");
  return String(secret);
}
function derivedKey(label) {
  return crypto.createHash("sha256").update(label + "\0" + pushMasterSecret()).digest();
}
function vapidKeys() {
  let seed = derivedKey("ttendencias-vapid");
  for (let i = 0; i < 32; i++) {
    try {
      const ecdh = crypto.createECDH("prime256v1");
      ecdh.setPrivateKey(seed);
      return {
        publicKey: b64url(ecdh.getPublicKey(null, "uncompressed")),
        privateKey: b64url(seed),
      };
    } catch (_) {
      seed = crypto.createHash("sha256").update(seed).update(String(i)).digest();
    }
  }
  throw new Error("No se pudo derivar la clave VAPID");
}
function subscriptionId(subscription) {
  return crypto.createHash("sha256").update(String(subscription?.endpoint || "")).digest("hex").slice(0, 24);
}
function encryptSubscription(subscription) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", derivedKey("ttendencias-subscriptions"), iv);
  const plaintext = Buffer.from(JSON.stringify(subscription), "utf8");
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return {
    id: subscriptionId(subscription),
    iv: b64url(iv),
    tag: b64url(cipher.getAuthTag()),
    data: b64url(encrypted),
    created_at: new Date().toISOString(),
  };
}
function fromB64url(value) {
  const s = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(s + "=".repeat((4 - (s.length % 4)) % 4), "base64");
}
function decryptSubscription(row) {
  const decipher = crypto.createDecipheriv("aes-256-gcm", derivedKey("ttendencias-subscriptions"), fromB64url(row.iv));
  decipher.setAuthTag(fromB64url(row.tag));
  const plain = Buffer.concat([decipher.update(fromB64url(row.data)), decipher.final()]).toString("utf8");
  return JSON.parse(plain);
}
function preparedKey(item) {
  return String(item?.id || item?.trend_name || "") + ":" + String(item?.revision || 0);
}
async function subscribePush(subscription) {
  if (!subscription?.endpoint || !String(subscription.endpoint).startsWith("https://")) throw new Error("Suscripción Web Push no válida");
  if (!subscription?.keys?.p256dh || !subscription?.keys?.auth) throw new Error("Claves Web Push incompletas");
  const { doc: recent } = await readJson(RECENT);
  const now = new Date().toISOString();
  const encrypted = encryptSubscription(subscription);
  await mutateJson(PUSH_STATE, "Registrar dispositivo Web Push TTendencias", doc => {
    doc.project ||= "TTendencias";
    doc.subscriptions ||= [];
    doc.subscriptions = doc.subscriptions.filter(x => x?.id !== encrypted.id);
    doc.subscriptions.push(encrypted);
    doc.pending_top10 = [];
    doc.last_scanned_capture = recent.captured_at || now;
    doc.top10_snapshot = (recent.items || []).slice(0, 10).map(x => ({ name: String(x.name || ""), rank: Number(x.rank || 0) }));
    doc.updated_at = now;
    return doc;
  });
  return { ok: true, subscribed: true };
}

async function unsubscribePush(subscription) {
  const id = subscriptionId(subscription || {});
  if (!id) throw new Error("Suscripción no válida");
  const now = new Date().toISOString();
  await mutateJson(PUSH_STATE, "Retirar dispositivo Web Push TTendencias", doc => {
    doc.project ||= "TTendencias";
    doc.subscriptions = (doc.subscriptions || []).filter(x => x?.id !== id);
    doc.updated_at = now;
    return doc;
  });
  return { ok: true, subscribed: false };
}

async function testPush() {
  const { doc: state } = await readJson(PUSH_STATE);
  const rows = state.subscriptions || [];
  if (!rows.length) return { ok: false, delivered: 0, failed: 0, no_subscribers: true };
  const keys = vapidKeys();
  webpush.setVapidDetails("https://github.com/fabricelop/europapress-rss", keys.publicKey, keys.privateKey);
  const payload = JSON.stringify({
    title: "TTendencias · prueba de avisos",
    body: "Los avisos al móvil funcionan correctamente.",
    url: "/ttendencias/",
    count: 0,
  });
  let delivered = 0, failed = 0;
  const dead = new Set(), errors = [];
  for (const row of rows) {
    try {
      const subscription = decryptSubscription(row);
      await webpush.sendNotification(subscription, payload, { TTL: 300, urgency: "high" });
      delivered++;
    } catch (e) {
      failed++;
      const status = Number(e?.statusCode || e?.status || 0);
      if (status === 404 || status === 410) dead.add(String(row?.id || ""));
      errors.push({ status: status || null, message: String(e?.message || e).slice(0, 180) });
    }
  }
  if (dead.size) {
    await mutateJson(PUSH_STATE, "Limpiar suscripciones Web Push TTendencias", doc => {
      doc.subscriptions = (doc.subscriptions || []).filter(x => !dead.has(String(x?.id || "")));
      doc.updated_at = new Date().toISOString();
      return doc;
    });
  }
  return { ok: delivered > 0, delivered, failed, removed_subscriptions: dead.size, errors: errors.slice(0,5) };
}
async function scanPush() {
  const [{ doc: recent }, { doc: state }] = await Promise.all([
    readJson(RECENT),
    readJson(PUSH_STATE),
  ]);
  const capture = String(recent.captured_at || "");
  const rankMap = new Map((recent.items || []).slice(0, 10).map(x => [norm(x.name), Number(x.rank || 0)]));
  const pendingMap = new Map((state.pending_top10 || []).map(x => [norm(x.name), x]));

  if (capture && capture !== String(state.last_scanned_capture || "")) {
    for (const name of recent.new_entries || []) {
      const clean = String(name || "").trim();
      if (!clean) continue;
      pendingMap.set(norm(clean), { name: clean, rank: rankMap.get(norm(clean)) || null, entered_at: capture });
    }
  }

  const pending = [...pendingMap.values()].sort((x, y) =>
    (Number(x.rank || 99) - Number(y.rank || 99)) || String(x.name).localeCompare(String(y.name), "es")
  );
  const rows = state.subscriptions || [];
  const lastPush = Date.parse(String(state.last_top10_push_at || "")) || 0;
  const cooldown = 30 * 60 * 1000;
  const remaining = Math.max(0, cooldown - (Date.now() - lastPush));

  if (!pending.length || !rows.length || remaining > 0) {
    const now = new Date().toISOString();
    await mutateJson(PUSH_STATE, "Agrupar avisos Top 10 TTendencias", doc => {
      doc.project ||= "TTendencias";
      doc.pending_top10 = pending;
      doc.last_scanned_capture = capture || doc.last_scanned_capture || null;
      doc.top10_snapshot = (recent.items || []).slice(0, 10).map(x => ({ name: String(x.name || ""), rank: Number(x.rank || 0) }));
      doc.last_scan_at = now;
      doc.last_result = {
        candidates: pending.length,
        delivered: 0,
        deferred: remaining > 0,
        cooldown_remaining_seconds: Math.ceil(remaining / 1000),
        no_subscribers: !rows.length,
      };
      doc.updated_at = now;
      return doc;
    });
    return { ok: true, candidates: pending.length, delivered: 0, deferred: remaining > 0, no_subscribers: !rows.length };
  }

  const keys = vapidKeys();
  webpush.setVapidDetails("https://github.com/fabricelop/europapress-rss", keys.publicKey, keys.privateKey);
  const shown = pending.slice(0, 5);
  const body = shown.map(x => (x.rank ? "#" + x.rank + " " : "") + x.name).join(" · ")
    + (pending.length > shown.length ? " · +" + (pending.length - shown.length) : "");
  const payload = JSON.stringify({
    title: pending.length === 1 ? "TTendencias · nuevo Top 10" : "TTendencias · nuevos Top 10",
    body,
    url: "/ttendencias/",
    count: pending.length,
    silent: true,
  });

  let delivered = 0, failed = 0;
  const dead = new Set(), errors = [];
  for (const row of rows) {
    try {
      const subscription = decryptSubscription(row);
      await webpush.sendNotification(subscription, payload, { TTL: 3600, urgency: "low" });
      delivered++;
    } catch (e) {
      failed++;
      const status = Number(e?.statusCode || e?.status || 0);
      if (status === 404 || status === 410) dead.add(String(row?.id || ""));
      errors.push({ status: status || null, message: String(e?.message || e).slice(0, 180) });
    }
  }

  const now = new Date().toISOString();
  await mutateJson(PUSH_STATE, "Actualizar avisos Top 10 TTendencias", doc => {
    doc.project ||= "TTendencias";
    doc.subscriptions = (doc.subscriptions || []).filter(x => !dead.has(String(x?.id || "")));
    doc.last_scanned_capture = capture || doc.last_scanned_capture || null;
    doc.top10_snapshot = (recent.items || []).slice(0, 10).map(x => ({ name: String(x.name || ""), rank: Number(x.rank || 0) }));
    if (delivered > 0) {
      doc.pending_top10 = [];
      doc.last_top10_push_at = now;
    } else {
      doc.pending_top10 = pending;
    }
    doc.last_scan_at = now;
    doc.last_result = { candidates: pending.length, delivered, failed, removed_subscriptions: dead.size, errors: errors.slice(0, 5) };
    doc.updated_at = now;
    return doc;
  });

  return { ok: delivered > 0 || failed === 0, candidates: pending.length, delivered, failed, removed_subscriptions: dead.size, errors: errors.slice(0, 5) };
}

async function queueNames(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const { doc: recent } = await readJson(RECENT);
  const current = new Map((recent.items || []).map(x => [norm(x.name), x]));
  for (const name of unique) if (!current.has(norm(name))) throw new Error(`"${name}" ya no está en el Top 10 actual.`);

  const { doc: explained } = await readJson(EXPLAINED);
  const explainedSet = new Set((explained.items || []).flatMap(explanationNames).map(norm));
  const now = new Date().toISOString();
  const batchId = crypto.createHash("sha256").update(unique.join(" | ") + " | " + now).digest("hex").slice(0, 12);

  await mutateJson(REQUESTS, "Encolar lote TTendencias desde web", doc => {
    doc.requests ||= [];
    const byId = new Map(doc.requests.filter(x => x?.id).map(x => [String(x.id), x]));
    for (const name of unique) {
      const item = current.get(norm(name));
      const id = crypto.createHash("sha256").update(name).digest("hex").slice(0, 12);
      const existing = [...byId.values()].find(x => norm(x.name) === norm(name) && ["preparing", "ready", "update"].includes(String(x.status || "")));
      if (existing) {
        existing.batch_id = batchId;
        existing.requested_together = unique;
        existing.with_image = true;
        existing.alternatives_target = 0;
        existing.task = "explain";
        if (String(existing.status || "") === "ready") {
          existing.status = "update";
          existing.requested_at = now;
          existing.revision = Number(existing.revision || 0) + 1;
          existing.reexplain = true;
          delete existing.telegram_message_id;
        }
      } else {
        const previous = [...byId.values()].find(x => norm(x.name) === norm(name));
        const reexplain = explainedSet.has(norm(name));
        byId.set(id, {
          id,
          name,
          rank: Number(item.rank),
          status: reexplain ? "update" : "preparing",
          requested_at: now,
          revision: Number(previous?.revision || 0) + (reexplain ? 1 : 0),
          reexplain,
          with_image: true,
          alternatives_target: 0,
          batch_id: batchId,
          requested_together: unique,
          task: "explain",
        });
      }
    }
    doc.requests = [...byId.values()];
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, queued: unique, batch_id: batchId };
}
function hasMaterialRadarNovelty(signal, explainedAt) {
  const sources = Number(signal?.news_source_count || 0);
  const firstSeen = new Date(signal?.news_first_seen || 0).getTime();
  const explained = new Date(explainedAt || 0).getTime();
  return sources >= 4 && Number.isFinite(firstSeen) && firstSeen > 0 && Number.isFinite(explained) && explained > 0 && firstSeen > explained + 10 * 60 * 1000;
}

async function queueUpcomingNames(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay señales seleccionadas.");
  const [{ doc: recent }, { doc: explained }] = await Promise.all([readJson(RECENT), readJson(EXPLAINED)]);
  const upcoming = new Map((recent.upcoming || []).map(x => [norm(x.name), x]));
  const explainedMap = new Map();
  for (const row of (explained.items || [])) for (const name of explanationNames(row)) explainedMap.set(norm(name), row);
  for (const name of unique) {
    const signal = upcoming.get(norm(name));
    if (!signal) throw new Error(`"${name}" ya no está en Próximas tendencias.`);
    const previous = explainedMap.get(norm(name));
    if (previous && !hasMaterialRadarNovelty(signal, previous.explained_at)) {
      throw new Error(`"${name}" ya fue explicada y no hay una novedad material verificada.`);
    }
  }
  const now = new Date().toISOString();

  await mutateJson(REQUESTS, "Explicar tendencia anticipada desde Radar", doc => {
    doc.requests ||= [];
    for (const name of unique) {
      const signal = upcoming.get(norm(name));
      let req = [...doc.requests].reverse().find(x => norm(x.name) === norm(name));
      const existingStatus = String(req?.status || "");
      if (!req) {
        req = {
          id: crypto.createHash("sha256").update(name).digest("hex").slice(0, 12),
          name,
          revision: 0,
        };
        doc.requests.push(req);
      } else if (["explained", "dismissed", "problematic"].includes(existingStatus)) {
        req.revision = Number(req.revision || 0) + 1;
        req.reexplain = true;
      }
      if (!["preparing", "update", "ready"].includes(existingStatus)) {
        req.status = req.reexplain ? "update" : "preparing";
        req.requested_at = now;
      }
      req.rank = Number(signal.best_observed_rank || 0);
      req.with_image = true;
      req.alternatives_target = 0;
      req.anticipated = true;
      req.anticipated_at = signal.first_detected_at || now;
      req.anticipated_best_rank = Number(signal.best_observed_rank || 0);
      req.anticipated_social_source_count = Number(signal.social_source_count || 0);
      req.anticipated_news_source_count = Number(signal.news_source_count || 0);
      req.anticipated_news_title = String(signal.news_title || "");
      req.requested_together = [name];
      req.auto_queued = false;
      delete req.dismissed_at;
      delete req.dismissed_source;
      delete req.problem_reason;
      delete req.problematic_at;
      delete req.explained_at;
      delete req.telegram_message_id;
    }
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, queued_upcoming: unique };
}

async function markExplained(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const target = new Set(unique.map(norm));

  // Protección contra agrupaciones editoriales defectuosas: un mismo grupo
  // relacionado debe existir como UNA sola tarjeta preparada. Si varias
  // tarjetas se solapan con el mismo conjunto, no cerramos nada en bloque.
  if (unique.length > 1) {
    const { doc: preparedBefore } = await readJson(PREPARED);
    const sameSet = values => {
      const keys = [...new Set((values || []).map(norm))].sort();
      const wanted = [...target].sort();
      return keys.length === wanted.length && keys.every((v, i) => v === wanted[i]);
    };
    const overlapping = (preparedBefore.items || []).filter(item => {
      const rel = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]).map(norm);
      return rel.some(x => target.has(x));
    });
    const exact = overlapping.filter(item => sameSet((item.related_trends || []).length ? item.related_trends : [item.trend_name]));
    if (overlapping.length !== 1 || exact.length !== 1) {
      throw new Error("Grupo editorial ambiguo: se ha evitado marcar varias tendencias como explicadas. Recarga la bandeja y revisa la agrupación.");
    }
  }

  const now = new Date().toISOString();
  const [{ doc: recentNow }, { doc: preparedNow }, { doc: requestsNow }] = await Promise.all([
    readJson(RECENT), readJson(PREPARED), readJson(REQUESTS)
  ]);
  const recentSignals = new Map((recentNow.upcoming || []).map(x => [norm(x.name), x]));
  const preparedByName = new Map();
  for (const item of preparedNow.items || []) {
    const rel = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]);
    for (const name of rel) preparedByName.set(norm(name), item);
  }
  const requestByName = new Map((requestsNow.requests || []).map(x => [norm(x.name), x]));
  const explainedContext = new Map();
  for (const name of unique) {
    const key = norm(name), signal = recentSignals.get(key), preparedItem = preparedByName.get(key), requestItem = requestByName.get(key);
    explainedContext.set(key, {
      id: preparedItem?.id || requestItem?.id || undefined,
      revision: preparedItem?.revision ?? requestItem?.revision ?? 0,
      news_event_id: signal?.news_event_id || requestItem?.anticipated_news_event_id || null,
      news_title: signal?.news_title || requestItem?.anticipated_news_title || "",
      explanation: preparedItem?.explanation || "",
      closer_text: preparedItem?.closer_text || "",
      verification_sources: preparedItem?.verification_sources || requestItem?.verification_sources || [],
      ai_image: preparedItem?.ai_image,
      ai_image_status: preparedItem?.ai_image_status,
      ai_image_attempt: preparedItem?.ai_image_attempt,
      fallback_image: preparedItem?.fallback_image,
      fallback_image_status: preparedItem?.fallback_image_status,
      image_choice: preparedItem?.image_choice,
      image: preparedItem?.image,
      image_status: preparedItem?.image_status,
      image_pending: preparedItem?.image_pending,
    });
  }

  await mutateJson(EXPLAINED, "Marcar TTendencias explicadas desde web", doc => {
    doc.project ||= "TTendencias";
    doc.items ||= [];
    const byName = new Map(doc.items.map((x, i) => [norm(x.name), i]));
    for (const name of unique) {
      const key = norm(name);
      if (byName.has(key)) {
        const i = byName.get(key);
        doc.items[i] = { ...doc.items[i], name, explained_at: now, source: "web_control", ...explainedContext.get(key) };
      } else {
        doc.items.push({ name, explained_at: now, source: "web_control", ...explainedContext.get(key) });
        byName.set(key, doc.items.length - 1);
      }
    }
    return doc;
  });
  await mutateJson(REQUESTS, "Actualizar estado TTendencias desde web", doc => {
    doc.requests ||= [];
    for (const req of doc.requests) {
      if (target.has(norm(req.name)) && req.status !== "explained") {
        req.status = "explained";
        req.explained_at = now;
        delete req.telegram_message_id;
      }
    }
    return doc;
  });
  await mutateJson(PREPARED, "Retirar tuits cerrados de TTendencias web", doc => {
    doc.project ||= "TTendencias";
    doc.items = (doc.items || []).filter(item => {
      const related = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, explained: unique };
}

async function requestImageRegeneration(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const target = new Set(unique.map(norm));
  const now = new Date().toISOString();
  let found = 0;
  await mutateJson(EXPLAINED, "Solicitar regeneración de imagen IA TTendencias", doc => {
    doc.items ||= [];
    for (let i = doc.items.length - 1; i >= 0; i--) {
      const row = doc.items[i];
      if (!target.has(norm(row.name)) || found >= unique.length) continue;
      row.ai_image_regenerate_requested = true;
      row.ai_image_regenerate_requested_at = now;
      row.ai_image_regenerate_request_version = Number(row.ai_image_regenerate_request_version || 0) + 1;
      found++;
    }
    doc.updated_at = now;
    return doc;
  });
  if (!found) throw new Error("No se encontró la tendencia explicada.");
  return { ok: true, requested: unique, image_regeneration: true };
}

async function useFallbackImage(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const target = new Set(unique.map(norm));
  const now = new Date().toISOString();
  let changed = 0;
  await mutateJson(EXPLAINED, "Usar imagen de archivo en TTendencias", doc => {
    doc.items ||= [];
    for (let i = doc.items.length - 1; i >= 0; i--) {
      const row = doc.items[i];
      if (!target.has(norm(row.name)) || changed >= unique.length) continue;
      const fallback = row.fallback_image || {};
      if (!/^https:\/\//i.test(String(fallback.url || ""))) continue;
      row.image = { ...fallback };
      row.image_choice = "fallback";
      row.image_status = "ready";
      row.image_pending = false;
      row.image_selected_at = now;
      changed++;
    }
    doc.updated_at = now;
    return doc;
  });
  if (!changed) throw new Error("Todavía no hay imagen de archivo/fallback disponible.");
  return { ok: true, selected: unique, image_choice: "fallback" };
}

async function discardNames(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const target = new Set(unique.map(norm));
  const now = new Date().toISOString();

  await mutateJson(REQUESTS, "Desestimar TTendencias desde web", doc => {
    doc.requests ||= [];
    for (const name of unique) {
      let req = [...doc.requests].reverse().find(x => norm(x.name) === norm(name));
      if (!req) {
        req = {
          id: crypto.createHash("sha256").update(name).digest("hex").slice(0, 12),
          name,
          rank: 0,
          revision: 0,
          with_image: true,
          alternatives_target: 0,
        };
        doc.requests.push(req);
      }
      req.status = "dismissed";
      req.dismissed_at = now;
      req.dismissed_source = "web_control";
      delete req.telegram_message_id;
      delete req.problem_reason;
      delete req.problematic_at;
    }
    return doc;
  });

  await mutateJson(PREPARED, "Retirar TTendencias desestimadas de la bandeja", doc => {
    doc.project ||= "TTendencias";
    doc.items = (doc.items || []).filter(item => {
      const related = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, dismissed: unique };
}

async function reworkNames(names, instruction) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const text = String(instruction || "").trim();
  if (!text) throw new Error("Añade una instrucción para rehacer la explicación.");
  const target = new Set(unique.map(norm));
  const now = new Date().toISOString();
  const { doc: explained } = await readJson(EXPLAINED);
  const latestByName = new Map();
  for (const row of explained.items || []) {
    const key = norm(row.name);
    if (!target.has(key)) continue;
    const prev = latestByName.get(key);
    if (!prev || Number(row.revision || 0) > Number(prev.revision || 0) ||
        (Number(row.revision || 0) === Number(prev.revision || 0) && String(row.explained_at || "") > String(prev.explained_at || ""))) {
      latestByName.set(key, row);
    }
  }

  await mutateJson(EXPLAINED, "Marcar reelaboración pendiente TTendencias desde web", doc => {
    doc.items ||= [];
    for (const name of unique) {
      const candidates = doc.items.filter(row => norm(row.name) === norm(name));
      if (!candidates.length) continue;
      candidates.sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||String(b.explained_at||"").localeCompare(String(a.explained_at||"")));
      const row=candidates[0];
      row.rewrite_pending=true;
      row.rewrite_requested_at=now;
      row.rewrite_request_version=Number(row.rewrite_request_version||0)+1;
      row.rewrite_instruction=text;
    }
    doc.updated_at=now;
    return doc;
  });

  await mutateJson(REQUESTS, "Reelaborar TTendencias con instrucciones desde web", doc => {
    doc.requests ||= [];
    for (const name of unique) {
      const latest = latestByName.get(norm(name));
      let req = [...doc.requests].reverse().find(x => norm(x.name) === norm(name));
      if (!req) {
        req = { id: crypto.createHash("sha256").update(name).digest("hex").slice(0, 12), name, rank: 0, revision: 0, with_image: true, alternatives_target: 0 };
        doc.requests.push(req);
      }
      req.status = "update";
      req.requested_at = now;
      req.revision = Math.max(Number(req.revision || 0), Number(latest?.revision || 0)) + 1;
      req.reexplain = true;
      req.rewrite_instruction = text;
      req.with_image = true;
      req.disable_ai_image = Boolean(latest?.tremending_origin);
      req.image_strategy = req.disable_ai_image ? "tweet_capture_only" : "ai_plus_fallback";
      if (req.disable_ai_image && latest?.fallback_image) req.selected_tweet_image = latest.fallback_image;
      delete req.problem_reason;
      delete req.problematic_at;
      req.alternatives_target = 0;
      delete req.telegram_message_id;
      delete req.explained_at;
    }
    doc.updated_at=now;
    return doc;
  });

  await mutateJson(PREPARED, "Retirar versión a reelaborar de TTendencias web", doc => {
    doc.items = (doc.items || []).filter(item => {
      const related = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, rework: unique, instruction: text, rewrite_pending: true };
}
async function retryNames(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const { doc: recent } = await readJson(RECENT);
  const current = new Map((recent.items || []).map(x => [norm(x.name), x]));
  for (const name of unique) if (!current.has(norm(name))) throw new Error(`"${name}" ya no está en el Top 10 actual.`);
  const now = new Date().toISOString();

  await mutateJson(REQUESTS, "Reintentar TTendencias desde web", doc => {
    doc.requests ||= [];
    for (const name of unique) {
      const item = current.get(norm(name));
      let req = [...doc.requests].reverse().find(x => norm(x.name) === norm(name));
      if (!req) {
        req = {
          id: crypto.createHash("sha256").update(name).digest("hex").slice(0, 12),
          name,
          revision: 0,
          with_image: true,
          alternatives_target: 0,
        };
        doc.requests.push(req);
      }
      req.rank = Number(item.rank);
      req.status = "update";
      req.requested_at = now;
      req.revision = Number(req.revision || 0) + 1;
      req.reexplain = true;
      req.with_image = true;
      req.alternatives_target = 0;
      delete req.dismissed_at;
      delete req.dismissed_source;
      delete req.problem_reason;
      delete req.problematic_at;
      delete req.telegram_message_id;
      delete req.explained_at;
    }
    return doc;
  });

  await mutateJson(PREPARED, "Limpiar versión anterior al reintentar TTendencias", doc => {
    const target = new Set(unique.map(norm));
    doc.items = (doc.items || []).filter(item => {
      const related = ((item.related_trends || []).length ? item.related_trends : [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, retried: unique };
}

async function markExplanationCopied(copyKey, source = "copy-button") {
  const key = String(copyKey || "").trim();
  if (!/^explanation-v1:[a-f0-9]{24}$/.test(key)) throw new Error("Explicación no válida.");
  const [{ doc: explained }, { doc: requests }] = await Promise.all([
    readJson(EXPLAINED),
    readJson(REQUESTS),
  ]);
  // El panel muestra la vista reconciliada: una request explicada más reciente puede
  // sustituir la revisión persistida en EXPLAINED. El botón debe validar contra esa
  // misma vista, no contra el histórico crudo, o genera falsos "otra revisión".
  const reconciled = reconcileExplainedView(explained, requests);
  const item = (reconciled.items || []).find(entry => explanationCopyIdentity(entry) === key);
  if (!item) throw new Error("La explicación ya no está disponible; recarga la bandeja.");
  const now = new Date().toISOString();
  let record;
  await mutateJson(EXPLAINED_COPY_STATE, source === "archive-button" ? "Pasar explicación TTendencias a histórico" : "Marcar explicación TTendencias como copiada", doc => {
    doc.project ||= "TTendencias";
    doc.version ||= 1;
    doc.items ||= [];
    record = doc.items.find(entry => entry?.key === key) || null;
    if (!record) {
      record = buildCopyRecord(item, now);
      record.source = source;
      doc.items.push(record);
      doc.updated_at = now;
    }
    return doc;
  });
  return { ok: true, copy_key: key, copied: true, copied_at: record?.copied_at || now, source: record?.source || source };
}

// Una sola valoración editable por versión exacta de explicación/remate.
// Toda lectura y escritura se valida contra el registro vivo, no contra el navegador.
async function rateRemate(ratingKey, rating) {
  const key = String(ratingKey || "").trim();
  const value = Number(rating);
  if (!/^remate-v1:[a-f0-9]{24}$/.test(key) ||
      !Number.isInteger(value) || value < 1 || value > 5) {
    throw new Error("Clave o valoración de remate no válida.");
  }
  const [{ doc: explained }, { doc: requests }] = await Promise.all([
    readJson(EXPLAINED),
    readJson(REQUESTS),
  ]);
  const reconciled = reconcileExplainedView(explained, requests);
  const item = (reconciled.items || []).find(entry => remateRatingIdentity(entry) === key);
  if (!item) throw new Error("Esta versión de la explicación ya no está disponible; recarga la bandeja.");
  const now = new Date().toISOString();
  let saved;
  await mutateJson(REMATE_RATINGS, "TTendencias: valorar remate editorial", doc => {
    doc.project ||= "TTendencias";
    doc.version ||= 1;
    doc.items ||= [];
    const existing = doc.items.find(entry => entry?.key === key);
    if (existing && existing.rating === value) { saved = existing; return doc; }
    const record = buildRemateRatingRecord(item, value, now);
    if (existing) {
      Object.assign(existing, record, { created_at: existing.created_at || now });
      saved = existing;
    } else {
      doc.items.push(record);
      saved = record;
    }
    doc.updated_at = now;
    return doc;
  });
  return {
    ok: true, rating_key: key, rating: saved.rating,
    rated_at: saved.updated_at,
  };
}

async function stateSnapshot() {
  const [recent, requests, explained, explainedCopyState, health, prepared, editorialConfig, editorialQueue, remateRatings] = await Promise.all([
    readPublicJson(RECENT),
    readJson(REQUESTS),
    readJson(EXPLAINED),
    readJson(EXPLAINED_COPY_STATE),
    readPublicJson(HEALTH),
    readJson(PREPARED),
    readPublicJson(EDITORIAL_CONFIG),
    readJson(EDITORIAL_QUEUE),
    readPublicJson(REMATE_RATINGS),
  ]);

  // Autorreparación del refresco: si GitHub retrasa o pierde ejecuciones cron,
  // una lectura real del panel fuerza el workflow mediante el trigger. Se
  // limita a una vez cada 8 minutos para evitar tormentas de commits.
  let refresh_recovery = { stale: false, triggered: false, age_minutes: null };
  try {
    const captured = new Date(recent.doc?.captured_at || 0).getTime();
    const ageMinutes = captured ? Math.max(0, (Date.now() - captured) / 60000) : 99999;
    refresh_recovery.age_minutes = Math.round(ageMinutes * 10) / 10;
    refresh_recovery.stale = ageMinutes > 20;
    if (refresh_recovery.stale) {
      const current = await readText(REFRESH_TRIGGER);
      const match = String(current.text || "").match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)/);
      const last = match ? new Date(match[1]).getTime() : 0;
      if (!last || Date.now() - last > 8 * 60 * 1000) {
        const stamp = new Date().toISOString();
        await writeText(REFRESH_TRIGGER, "Autorreparar refresco TTendencias desde panel", `panel-watchdog ${stamp}\n`);
        refresh_recovery.triggered = true;
        refresh_recovery.triggered_at = stamp;
      }
    }
  } catch (e) {
    refresh_recovery.error = String(e?.message || e).slice(0, 300);
  }

  return {
    ok: true,
    service: "ttendencias-control",
    branch: BRANCH,
    fetched_at: new Date().toISOString(),
    recent: recent.doc,
    requests: requests.doc,
    explained: annotateRemateRatings(annotateExplainedCopyState(reconcileExplainedView(explained.doc, requests.doc), explainedCopyState.doc), remateRatings.doc),
    explained_copy_state: explainedCopyState.doc,
    health: health.doc,
    prepared: prepared.doc,
    editorial_config: editorialConfig.doc,
    editorial_queue: editorialQueue.doc,
    refresh_recovery,
  };
}

async function proxyPreparedImage(rawUrl, res, format = "") {
  const url = String(rawUrl || "");
  let parsed;
  try { parsed = new URL(url); } catch (_) { throw new Error("URL de imagen no válida"); }
  if (parsed.protocol !== "https:") throw new Error("Solo se permiten imágenes HTTPS");
  const [{ doc: prepared }, { doc: explained }, { doc: requests }] = await Promise.all([
    readPublicJson(PREPARED),
    readPublicJson(EXPLAINED),
    readJson(REQUESTS),
  ]);
  const allowed = new Set([
    ...(prepared.items || []),
    ...(explained.items || []),
    ...(requests.requests || []),
  ].flatMap(x => [
    x?.image?.url || x?.image_url,
    x?.ai_image?.url,
    x?.fallback_image?.url,
  ]).filter(Boolean).map(String));
  if (!allowed.has(url)) throw new Error("Imagen no autorizada");
  const r = await fetch(url, { headers: { "user-agent": "TTendencias-Image-Proxy/1.0", accept: "image/*" } });
  if (!r.ok) throw new Error(`No se pudo descargar la imagen: ${r.status}`);
  const type = String(r.headers.get("content-type") || "");
  if (!type.startsWith("image/")) throw new Error("El recurso no es una imagen");
  let buf = Buffer.from(await r.arrayBuffer());
  if (buf.length > 12 * 1024 * 1024) throw new Error("Imagen demasiado grande");
  let outputType = type;
  if (String(format).toLowerCase() === "png") {
    buf = await sharp(buf, { density: 180 }).png({ compressionLevel: 9 }).toBuffer();
    outputType = "image/png";
  }
  res.setHeader("content-type", outputType);
  res.setHeader("content-length", String(buf.length));
  res.setHeader("cache-control", "no-store");
  return res.status(200).send(buf);
}

async function backendStatus() {
  const r = await gh(`contents/${RECENT}?ref=${encodeURIComponent(BRANCH)}`, { cache: "no-store" });
  if (!r.ok) {
    return { ok: false, status: r.status, detail: (await r.text()).slice(0, 300) };
  }
  return { ok: true, status: r.status };
}

export default async function handler(req, res) {
  res.setHeader("cache-control", "no-store");
  try {
    if (req.method === "GET") {
      if (String(req.query?.view || "") === "state") {
        return res.status(200).json(await stateSnapshot());
      }
      if (String(req.query?.view || "") === "image-proxy") {
        return await proxyPreparedImage(req.query?.url, res, req.query?.format);
      }
      if (String(req.query?.view || "") === "push-key") {
        return res.status(200).json({ ok: true, publicKey: vapidKeys().publicKey });
      }
      if (String(req.query?.view || "") === "push-scan") {
        if (!authorized(req) && !(await authorizedGitHubWorkflow(req))) {
          return res.status(401).json({ ok: false, error: "No autorizado" });
        }
        return res.status(200).json(await scanPush());
      }
      const backend = await backendStatus();
      return res.status(backend.ok ? 200 : 503).json({
        ok: backend.ok,
        service: "ttendencias-control",
        backend: { ok: backend.ok, status: backend.status }
      });
    }
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Método no permitido" });
    if (!authorized(req)) return res.status(401).json({ ok: false, error: "No autorizado" });

    const body = req.body || {};
    const action = String(body.action || "");
    if (action === "ping") {
      const backend = await backendStatus();
      return res.status(backend.ok ? 200 : 503).json({
        ok: backend.ok,
        access: "granted",
        backend,
        error: backend.ok ? undefined : "Token de control válido, pero esta instancia no tiene acceso válido a GitHub."
      });
    }
    if (action === "push-subscribe") return res.status(200).json(await subscribePush(body.subscription));
    if (action === "push-unsubscribe") return res.status(200).json(await unsubscribePush(body.subscription));
    if (action === "push-test") {
      const result = await testPush();
      return res.status(result.ok ? 200 : 503).json(result);
    }
    if (action === "queue") return res.status(200).json(await queueNames(body.names));
    if (action === "queue-upcoming") return res.status(200).json(await queueUpcomingNames(body.names));
    if (action === "explained") return res.status(200).json(await markExplained(body.names));
    if (action === "copy-explained") return res.status(200).json(await markExplanationCopied(body.copy_key));
    if (action === "archive-explained") return res.status(200).json(await markExplanationCopied(body.copy_key, "archive-button"));
    if (action === "rate-remate") {
      if (!/^remate-v1:[a-f0-9]{24}$/.test(String(body.rating_key || "")) ||
          !Number.isInteger(body.rating) || body.rating < 1 || body.rating > 5) {
        return res.status(400).json({ ok: false, error: "Envía una explicación válida y de 1 a 5 estrellas." });
      }
      return res.status(200).json(await rateRemate(body.rating_key, body.rating));
    }
    if (action === "discard") return res.status(200).json(await discardNames(body.names));
    if (action === "retry") return res.status(200).json(await retryNames(body.names));
    if (action === "rework") return res.status(200).json(await reworkNames(body.names, body.instruction));
    if (action === "regenerate-image") return res.status(200).json(await requestImageRegeneration(body.names));
    if (action === "use-fallback-image") return res.status(200).json(await useFallbackImage(body.names));
    return res.status(400).json({ ok: false, error: "Acción no válida" });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false, error: String(e.message || e) });
  }
}
