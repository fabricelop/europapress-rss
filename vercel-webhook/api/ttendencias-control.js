import crypto from "node:crypto";

const REPO = process.env.GITHUB_REPO || "fabricelop/europapress-rss";
const BRANCH = process.env.GITHUB_BRANCH || "main";
const RECENT = "trends/recent.json";
const REQUESTS = "trends/requests.json";
const EXPLAINED = "trends/telegram-manual-explained.json";
const PREPARED = "trends/prepared.json";

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
        existing.with_image = false;
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
          with_image: false,
          alternatives_target: 3,
          batch_id: batchId,
          requested_together: unique,
        });
      }
    }
    doc.requests = [...byId.values()];
    return doc;
  });
  return { ok: true, queued: unique, batch_id: batchId };
}
async function markExplained(names) {
  const unique = [...new Set((names || []).map(String).map(x => x.trim()).filter(Boolean))].slice(0, 10);
  if (!unique.length) throw new Error("No hay tendencias seleccionadas.");
  const target = new Set(unique.map(norm));
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
          with_image: false,
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
          with_image: false,
          alternatives_target: 3,
        };
        doc.requests.push(req);
      }
      req.status = "update";
      req.requested_at = now;
      req.revision = Number(req.revision || 0) + 1;
      req.reexplain = true;
      req.rewrite_instruction = text;
      req.with_image = false;
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
          with_image: false,
          alternatives_target: 3,
        };
        doc.requests.push(req);
      }
      req.rank = Number(item.rank);
      req.status = "update";
      req.requested_at = now;
      req.revision = Number(req.revision || 0) + 1;
      req.reexplain = true;
      req.with_image = false;
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
  return { ok: true, retried: unique };
}

async function backendStatus() {
  const r = await gh(`contents/${RECENT}?ref=${encodeURIComponent(BRANCH)}`);
  if (!r.ok) {
    return { ok: false, status: r.status, detail: (await r.text()).slice(0, 300) };
  }
  return { ok: true, status: r.status };
}

export default async function handler(req, res) {
  res.setHeader("cache-control", "no-store");
  try {
    if (req.method === "GET") {
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
    if (action === "queue") return res.status(200).json(await queueNames(body.names));
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
