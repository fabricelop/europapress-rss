import crypto from "node:crypto";
import { explanationCopyIdentity, explanationTrendNames } from "./ttendencias-copy-state.js";

// El remate es explícito en las explicaciones nuevas; para el histórico,
// se valora la última frase y se conserva una instantánea del texto valorado.
export function remateText(item) {
  const explanation = String(item?.explanation || "").trim();
  if (!explanation) return "";
  // Una explicación nueva con closer_text explícitamente vacío no tiene chiste puntuable.
  if (Object.prototype.hasOwnProperty.call(item || {}, "closer_text")) {
    const explicit = String(item.closer_text || "").trim();
    return explicit && explanation.endsWith(explicit) ? explicit : "";
  }
  const legacy = String(item?.remate || "").trim();
  if (legacy && explanation.endsWith(legacy)) return legacy;
  return explanation.split(/(?<=[.!?])\s+/u).at(-1).trim();
}

export function remateRatingIdentity(item) {
  const explanation = String(item?.explanation || "").trim();
  if (!explanation) return null;
  const digest = crypto.createHash("sha256")
    .update(JSON.stringify({
      explanation_key: explanationCopyIdentity(item),
      explanation,
    }))
    .digest("hex").slice(0, 24);
  return `remate-v1:${digest}`;
}

export function annotateRemateRatings(explained, ratings) {
  const byKey = new Map((ratings?.items || []).map(item => [item.key, item]));
  return {
    ...(explained || {}),
    items: (explained?.items || []).map(item => {
      const key = remateRatingIdentity(item);
      const record = byKey.get(key);
      return {
        ...item,
        rating_key: key,
        closer_text: remateText(item),
        remate_rating: Number.isInteger(record?.rating) && record.rating >= 1 && record.rating <= 5
          ? record.rating : null,
        remate_rated_at: record?.updated_at || null,
      };
    }),
  };
}

export function buildRemateRatingRecord(item, rating, at = new Date().toISOString()) {
  const value = Number(rating);
  if (!Number.isInteger(value) || value < 1 || value > 5) {
    throw new Error("La valoración debe ser un entero de 1 a 5.");
  }
  const key = remateRatingIdentity(item);
  if (!key) throw new Error("No existe explicación para puntuar.");
  return {
    key,
    explanation_key: explanationCopyIdentity(item),
    trend_names: explanationTrendNames(item),
    group_id: String(item?.group_id || "").trim() || null,
    group_title: String(item?.group_title || "").trim() || null,
    revision: Number.isFinite(Number(item?.revision)) ? Number(item.revision) : 0,
    explained_at: String(item?.explained_at || "").trim() || null,
    explanation: String(item.explanation).trim(),
    remate: remateText(item),
    rating: value,
    created_at: at,
    updated_at: at,
    source: "ttendencias-explicadas-stars",
  };
}
