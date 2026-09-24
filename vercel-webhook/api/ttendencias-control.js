import crypto from "node:crypto";
import webpush from "web-push";

const REPO = process.env.GITHUB_REPO || "fabricelop/europapress-rss";
const BRANCH = process.env.GITHUB_BRANCH || "main";
const RECENT = "trends/recent.json";
const REQUESTS = "trends/requests.json";
const EXPLAINED = "trends/telegram-manual-explained.json";
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
function authToken(req) {
  const h = String(req.headers.authorization || "");
  return h.startsWith("Bearer ") ? h.slice(7).trim() : "";
}
const CONTROL_TOKEN_HASH = "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5";
function authorized(req) {
  const got = authToken(req);
  if (!got) return false;
  const expected = process.env.TTENDENCIAS_CONTROL_TOKEN || "";
  if (expected) return got === expected;
  const digest = crypto.createHash("sha256").update(got).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(digest), Buffer.from(CONTROL_TOKEN_HASH));
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
  const { doc: requests } = await readJson(REQUESTS);
  const active = (requests.requests || [])
    .filter(req => ["preparing", "update"].includes(String(req.status || "")))
    .map(req => ({
      id: req.id,
      name: req.name,
      rank: req.rank,
      status: req.status,
      requested_at: req.requested_at,
      revision: Number(req.revision || 0),
      rewrite_instruction: req.rewrite_instruction || req.rewrite_request || "",
      with_image: Boolean(req.with_image),
      image_mode: "existing_web_image",
      image_instruction: "Busca una imagen existente y relevante en una fuente fiable. Guarda la URL directa de la imagen, la fuente y la URL de la página de origen. No generes una imagen.",
      auto_queued: Boolean(req.auto_queued),
      anticipated: Boolean(req.anticipated),
      anticipated_at: req.anticipated_at || null,
      anticipated_best_rank: req.anticipated_best_rank || null,
      anticipated_social_source_count: req.anticipated_social_source_count || 0,
      anticipated_news_source_count: req.anticipated_news_source_count || 0,
      anticipated_news_title: req.anticipated_news_title || "",
      anticipated_entered_top10_at: req.anticipated_entered_top10_at || null,
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
  const { doc: prepared } = await readJson(PREPARED);
  const now = new Date().toISOString();
  const encrypted = encryptSubscription(subscription);
  await mutateJson(PUSH_STATE, "Registrar dispositivo Web Push TTendencias", doc => {
    doc.project ||= "TTendencias";
    doc.subscriptions ||= [];
    doc.notified ||= {};
    doc.subscriptions = doc.subscriptions.filter(x => x?.id !== encrypted.id);
    doc.subscriptions.push(encrypted);
    for (const item of prepared.items || []) doc.notified[preparedKey(item)] ||= now;
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
    url: "/ttendencias/preparados/",
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
  const [{ doc: prepared }, { doc: requests }, { doc: state }] = await Promise.all([
    readJson(PREPARED),
    readJson(REQUESTS),
    readJson(PUSH_STATE),
  ]);
  const byId = new Map((requests.requests || []).filter(x => x?.id).map(x => [String(x.id), x]));
  const byName = new Map();
  for (const req of requests.requests || []) byName.set(norm(req?.name), req);
  const notified = state.notified || {};
  const candidates = (prepared.items || []).filter(item => {
    const req = byId.get(String(item?.id || "")) || byName.get(norm(item?.trend_name));
    const status = String(req?.status || "");
    const closed = ["explained", "dismissed", "problematic"].includes(status);
    return !closed && !notified[preparedKey(item)];
  });
  if (!candidates.length) {
    return { ok: true, candidates: 0, delivered: 0 };
  }

  const rows = state.subscriptions || [];
  if (!rows.length) {
    return { ok: true, candidates: candidates.length, delivered: 0, no_subscribers: true };
  }

  const keys = vapidKeys();
  webpush.setVapidDetails("https://github.com/fabricelop/europapress-rss", keys.publicKey, keys.privateKey);
  const names = candidates.map(x => String(x.trend_name || "").trim()).filter(Boolean);
  const payload = JSON.stringify({
    title: names.length === 1 ? "TTendencias · tuit listo" : `TTendencias · ${names.length} tuits listos`,
    body: names.length === 1 ? `${names[0]} ya está listo para revisar.` : names.slice(0, 4).join(" · ") + (names.length > 4 ? ` · +${names.length - 4}` : ""),
    url: "/ttendencias/preparados/",
    count: names.length,
  });

  let delivered = 0, failed = 0;
  const dead = new Set();
  const errors = [];
  for (const row of rows) {
    try {
      const subscription = decryptSubscription(row);
      await webpush.sendNotification(subscription, payload, { TTL: 3600, urgency: "high" });
      delivered++;
    } catch (e) {
      failed++;
      const status = Number(e?.statusCode || e?.status || 0);
      if (status === 404 || status === 410) dead.add(String(row?.id || ""));
      errors.push({ status: status || null, message: String(e?.message || e).slice(0, 180) });
      console.error("TTendencias push:", status || "", String(e?.message || e));
    }
  }

  const now = new Date().toISOString();
  await mutateJson(PUSH_STATE, "Actualizar entrega Web Push TTendencias", doc => {
    doc.project ||= "TTendencias";
    doc.subscriptions = (doc.subscriptions || []).filter(x => !dead.has(String(x?.id || "")));
    doc.notified ||= {};
    if (delivered > 0) for (const item of candidates) doc.notified[preparedKey(item)] = now;
    const entries = Object.entries(doc.notified).sort((a, b) => String(a[1]).localeCompare(String(b[1])));
    doc.notified = Object.fromEntries(entries.slice(-300));
    doc.last_scan_at = now;
    doc.last_result = {
      candidates: candidates.length,
      delivered,
      failed,
      removed_subscriptions: dead.size,
      errors: errors.slice(0, 5),
    };
    doc.updated_at = now;
    return doc;
  });
  return {
    ok: delivered > 0 || failed === 0,
    candidates: candidates.length,
    delivered,
    failed,
    removed_subscriptions: dead.size,
    errors: errors.slice(0, 5),
  };
}
async function queueNames(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const { doc: recent } = await readJson(RECENT);
  const current = new Map((recent.items || []).map(x => [norm(x.name), x]));
  for (const name of unique) if (!current.has(norm(name))) throw new Error(`"${name}" ya no está en el Top 10 actual.`);

  const { doc: explained } = await readJson(EXPLAINED);
  const explainedSet = new Set((explained.items || []).map(x => norm(x.name)));
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
        existing.alternatives_target = 3;
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
          alternatives_target: 3,
          batch_id: batchId,
          requested_together: unique,
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
  const explainedMap = new Map((explained.items || []).map(x => [norm(x.name), x]));
  for (const name of unique) {
    const signal = upcoming.get(norm(name));
    if (!signal) throw new Error(`"${name}" ya no está en Próximas tendencias.`);
    const previous = explainedMap.get(norm(name));
    if (previous && !hasMaterialRadarNovelty(signal, previous.explained_at)) {
      throw new Error(`"${name}" ya fue explicada y no hay una novedad material verificada.`);
    }
  }
  const now = new Date().toISOString();

  await mutateJson(REQUESTS, "Preparar tendencia anticipada desde Radar", doc => {
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
      req.alternatives_target = 3;
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

  await mutateJson(EXPLAINED, "Marcar TTendencias explicadas desde web", doc => {
    doc.project ||= "TTendencias";
    doc.items ||= [];
    const byName = new Map(doc.items.map((x, i) => [norm(x.name), i]));
    for (const name of unique) {
      const key = norm(name);
      if (byName.has(key)) {
        const i = byName.get(key);
        doc.items[i] = { ...doc.items[i], name, explained_at: now, source: "web_control" };
      } else {
        doc.items.push({ name, explained_at: now, source: "web_control" });
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
      const related = (item.related_trends || [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  return { ok: true, explained: unique };
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
          alternatives_target: 3,
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
      const related = (item.related_trends || [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  return { ok: true, dismissed: unique };
}

async function reworkNames(names, instruction) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const text = String(instruction || "").trim();
  if (!text) throw new Error("Añade una instrucción para rehacer la redacción.");
  const target = new Set(unique.map(norm));
  const now = new Date().toISOString();

  await mutateJson(REQUESTS, "Reelaborar TTendencias con instrucciones desde web", doc => {
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
          alternatives_target: 3,
        };
        doc.requests.push(req);
      }
      req.status = "update";
      req.requested_at = now;
      req.revision = Number(req.revision || 0) + 1;
      req.reexplain = true;
      req.rewrite_instruction = text;
      req.with_image = true;
      req.alternatives_target = 3;
      delete req.telegram_message_id;
      delete req.explained_at;
    }
    return doc;
  });

  await mutateJson(PREPARED, "Retirar versión a reelaborar de TTendencias web", doc => {
    doc.items = (doc.items || []).filter(item => {
      const related = (item.related_trends || [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, rework: unique, instruction: text };
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
          alternatives_target: 3,
        };
        doc.requests.push(req);
      }
      req.rank = Number(item.rank);
      req.status = "update";
      req.requested_at = now;
      req.revision = Number(req.revision || 0) + 1;
      req.reexplain = true;
      req.with_image = true;
      req.alternatives_target = 3;
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
      const related = (item.related_trends || [item.trend_name]).map(norm);
      return !related.some(x => target.has(x));
    });
    doc.updated_at = now;
    return doc;
  });
  await syncEditorialQueue();
  return { ok: true, retried: unique };
}

async function stateSnapshot() {
  const [recent, requests, explained, health, prepared, editorialConfig] = await Promise.all([
    readJson(RECENT),
    readJson(REQUESTS),
    readJson(EXPLAINED),
    readJson(HEALTH),
    readJson(PREPARED),
    readJson(EDITORIAL_CONFIG),
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
    explained: explained.doc,
    health: health.doc,
    prepared: prepared.doc,
    editorial_config: editorialConfig.doc,
    refresh_recovery,
  };
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
      if (String(req.query?.view || "") === "push-key") {
        return res.status(200).json({ ok: true, publicKey: vapidKeys().publicKey });
      }
      if (String(req.query?.view || "") === "push-scan") {
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
    if (action === "discard") return res.status(200).json(await discardNames(body.names));
    if (action === "retry") return res.status(200).json(await retryNames(body.names));
    if (action === "rework") return res.status(200).json(await reworkNames(body.names, body.instruction));
    return res.status(400).json({ ok: false, error: "Acción no válida" });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false, error: String(e.message || e) });
  }
}
