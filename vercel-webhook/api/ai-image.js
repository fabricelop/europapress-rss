import crypto from "node:crypto";
import { generateImage } from "ai";
import { createRemoteJWKSet, jwtVerify } from "jose";
import sharp from "sharp";

const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "tt-image-generator-v1";
const REPOSITORY = "fabricelop/europapress-rss";
const WORKFLOW_SUFFIX = "/.github/workflows/ai-image-generate.yml@refs/heads/main";
const MODEL = "openai/gpt-image-2";
const JWKS = createRemoteJWKSet(new URL(ISSUER + "/.well-known/jwks"));

function reply(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

async function authorize(req) {
  const header = String(req.headers.authorization || "");
  if (!header.startsWith("Bearer ")) {
    throw new Error("missing_bearer");
  }
  const token = header.slice(7).trim();
  const { payload } = await jwtVerify(token, JWKS, {
    issuer: ISSUER,
    audience: AUDIENCE,
  });
  if (payload.repository !== REPOSITORY) {
    throw new Error("wrong_repository");
  }
  if (payload.ref !== "refs/heads/main") {
    throw new Error("wrong_ref");
  }
  const workflowRef = String(payload.workflow_ref || "");
  if (!workflowRef.endsWith(WORKFLOW_SUFFIX)) {
    throw new Error("wrong_workflow");
  }
  return payload;
}

function cleanJob(input) {
  const project = String(input?.project || "").trim().toLowerCase();
  if (!["ttendencias", "ttittulares"].includes(project)) {
    throw new Error("invalid_project");
  }
  const id = String(input?.id || input?.event_id || "").trim();
  if (!/^[a-zA-Z0-9._-]{3,160}$/.test(id)) {
    throw new Error("invalid_id");
  }
  const revision = Math.max(0, Number.parseInt(input?.revision ?? (project === "ttittulares" ? 1 : 0), 10) || 0);
  const attempt = Math.max(1, Number.parseInt(input?.attempt ?? 1, 10) || 1);
  const prompt = String(input?.prompt || "").trim();
  if (prompt.length < 30 || prompt.length > 7000) {
    throw new Error("invalid_prompt");
  }
  const contextGuard = input?.context_guard && typeof input.context_guard === "object"
    ? input.context_guard
    : {
        version: 3,
        ...(project === "ttendencias" ? { trend_id: id } : { event_id: id }),
        revision,
        scope: "current_item_only",
      };
  return { project, id, revision, attempt, prompt, contextGuard };
}

async function normalizeImage(image) {
  let raw;
  if (image?.uint8Array) raw = Buffer.from(image.uint8Array);
  else if (image?.base64) raw = Buffer.from(image.base64, "base64");
  else throw new Error("gateway_returned_no_image_bytes");

  if (raw.length < 4096) throw new Error("gateway_returned_too_few_bytes");

  let out = await sharp(raw)
    .rotate()
    .resize(768, 432, { fit: "cover", position: "centre" })
    .jpeg({ quality: 78, mozjpeg: true })
    .toBuffer();

  if (out.length > 180000) {
    out = await sharp(raw)
      .rotate()
      .resize(768, 432, { fit: "cover", position: "centre" })
      .jpeg({ quality: 66, mozjpeg: true })
      .toBuffer();
  }
  if (out.length > 220000) {
    out = await sharp(raw)
      .rotate()
      .resize(640, 360, { fit: "cover", position: "centre" })
      .jpeg({ quality: 58, mozjpeg: true })
      .toBuffer();
  }
  if (out.length < 4096) throw new Error("normalized_image_too_small");
  return out;
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return reply(res, 405, { ok: false, error: "method_not_allowed" });
  }

  try {
    await authorize(req);
  } catch (error) {
    return reply(res, 401, { ok: false, error: "unauthorized", detail: String(error?.message || error).slice(0, 120) });
  }

  let input = req.body;
  if (typeof input === "string") {
    try { input = JSON.parse(input); }
    catch { return reply(res, 400, { ok: false, error: "invalid_json" }); }
  }

  let job;
  try {
    job = cleanJob(input);
  } catch (error) {
    return reply(res, 400, { ok: false, error: String(error?.message || error).slice(0, 160) });
  }

  try {
    const result = await generateImage({
      model: MODEL,
      prompt: job.prompt,
      n: 1,
      aspectRatio: "16:9",
      maxRetries: 1,
    });

    const bytes = await normalizeImage(result.image);
    const sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
    const dataUrl = "data:image/jpeg;base64," + bytes.toString("base64");

    return reply(res, 200, {
      ok: true,
      project: job.project,
      id: job.id,
      revision: job.revision,
      attempt: job.attempt,
      model: MODEL,
      bytes: bytes.length,
      sha256,
      media_type: "image/jpeg",
      data_url: dataUrl,
      context_guard: job.contextGuard,
      warnings: Array.isArray(result.warnings)
        ? result.warnings.map((x) => String(x?.message || x)).slice(0, 5)
        : [],
    });
  } catch (error) {
    const message = String(error?.message || error).replace(/\s+/g, " ").slice(0, 500);
    return reply(res, 502, {
      ok: false,
      error: "image_generation_failed",
      detail: message,
      project: job.project,
      id: job.id,
      revision: job.revision,
      attempt: job.attempt,
      model: MODEL,
      context_guard: job.contextGuard,
    });
  }
}
