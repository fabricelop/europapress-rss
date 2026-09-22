import crypto from "node:crypto";

const REPO = process.env.GITHUB_REPO || "fabricelop/europapress-rss";
const BRANCH = process.env.GITHUB_BRANCH || "main";
const RECENT = "trends/recent.json";
const REQUESTS = "trends/requests.json";
const EXPLAINED = "trends/telegram-manual-explained.json";

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
const CONTROL_TOKEN_HASH = "9b2f6099de2371ae0a6d781da69bbb7afe2e1ab4a270a059a21952cb8e457143";
function authorized(req) {
  const got = authToken(req);
  if (!got) return false;
  const dedicated = process.env.TTENDENCIAS_CONTROL_TOKEN || "";
  if (dedicated) return got === dedicated;
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
    const next = await mutator(doc);
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
function stateFor(name, requests, explainedSet) {
  const n = norm(name);
  const req = [...requests].reverse().find(x => norm(x.name) === n);
  const status = String(req?.status || "");
  if (status === "preparing") return { code: "preparing", label: "Elaborando" };
  if (status === "update") return { code: "update", label: "Actualizando" };
  if (status === "ready") return { code: "ready", label: "Preparada" };
  if (status === "explained" || explainedSet.has(n)) return { code: "explained", label: "Explicada" };
  return { code: "new", label: "Nueva" };
}
async function model() {
  const [{ doc: recent }, { doc: requestDoc }, { doc: explained }] = await Promise.all([
    readJson(RECENT), readJson(REQUESTS), readJson(EXPLAINED)
  ]);
  const requests = Array.isArray(requestDoc.requests) ? requestDoc.requests : [];
  const explainedSet = new Set((explained.items || []).map(x => norm(x.name)));
  const items = (recent.items || []).slice(0, 10).map(item => {
    const state = stateFor(item.name, requests, explainedSet);
    const req = [...requests].reverse().find(x => norm(x.name) === norm(item.name));
    return {
      rank: Number(item.rank),
      name: String(item.name),
      status: state.code,
      status_label: state.label,
      requested_at: req?.requested_at || null,
      telegram_message_id: req?.telegram_message_id || null,
    };
  });
  return {
    project: "TTendencias",
    captured_at: recent.captured_at || null,
    reliability: recent.reliability || null,
    source_count: recent.source_count || 0,
    non_stale_source_count: recent.non_stale_source_count || 0,
    items,
    pending: requests.filter(x => ["preparing", "update", "ready"].includes(String(x.status || ""))).map(x => ({
      id: x.id, name: x.name, rank: x.rank, status: x.status, requested_at: x.requested_at || null
    }))
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
        existing.with_image = false;
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
    const known = new Set(doc.items.map(x => norm(x.name)));
    for (const name of unique) {
      if (!known.has(norm(name))) {
        doc.items.push({ name, explained_at: now, source: "web_control" });
        known.add(norm(name));
      }
    }
    return doc;
  });
  await mutateJson(REQUESTS, "Actualizar estado TTendencias desde web", doc => {
    doc.requests ||= [];
    for (const req of doc.requests) {
      if (target.has(norm(req.name))) {
        req.status = "explained";
        req.explained_at = now;
        delete req.telegram_message_id;
      }
    }
    return doc;
  });
  return { ok: true, explained: unique };
}
async function refreshNow() {
  const r = await gh("actions/workflows/ttendencias-refresh.yml/dispatches", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ref: BRANCH }),
  });
  if (!r.ok) throw new Error(`No se pudo lanzar el refresco: ${r.status} ${await r.text()}`);
  return { ok: true };
}

export default async function handler(req, res) {
  res.setHeader("cache-control", "no-store");
  try {
    if (req.method === "GET") {
      return res.status(200).json(await model());
    }
    if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Método no permitido" });
    if (!authorized(req)) return res.status(401).json({ ok: false, error: "No autorizado" });

    const body = req.body || {};
    const action = String(body.action || "");
    if (action === "queue") return res.status(200).json(await queueNames(body.names));
    if (action === "explained") return res.status(200).json(await markExplained(body.names));
    if (action === "refresh") return res.status(200).json(await refreshNow());
    return res.status(400).json({ ok: false, error: "Acción no válida" });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false, error: String(e.message || e) });
  }
}
