import crypto from "node:crypto";

function variantsOf(item) {
  if (Array.isArray(item?.variants) && item.variants.length) return item.variants;
  return (item?.alternatives || []).map((a, i) => ({
    ...a, label: a.label || String.fromCharCode(65 + i),
    text: a.tweet_text || a.text || "", remate: a.remate || "",
  }));
}
function safeLabel(v) { return String(v?.label || v?.name || "").trim().toUpperCase(); }
export function isRatedVariant(v) {
  return ["A", "B", "C"].includes(safeLabel(v)) && Boolean(String(v?.remate || "").trim());
}
export function titularRemateIdentity(item, variant) {
  if (!isRatedVariant(variant)) return null;
  const eventId = String(item?.event_id || "").trim();
  if (!eventId) return null;
  const revision = Number(item?.revision || 0), label = safeLabel(variant);
  const text = String(variant?.text || variant?.tweet_text || "").trim();
  const remate = String(variant?.remate || "").trim();
  const digest = crypto.createHash("sha256")
    .update(JSON.stringify({ eventId, revision, label, text, remate }))
    .digest("hex").slice(0, 24);
  return `titular-remate-v1:${digest}`;
}
export function titularRemateVariants(item) {
  return variantsOf(item).filter(isRatedVariant);
}
export function annotateTitularRemates(prepared, ratings) {
  const byKey = new Map((ratings?.items || []).map(record => [record.key, record]));
  return {
    ...(prepared || {}),
    items: (prepared?.items || []).map(item => {
      const tag = v => {
        const key = titularRemateIdentity(item, v);
        const rec = byKey.get(key);
        return {
          ...v, rating_key: key,
          remate_rating: Number.isInteger(rec?.rating) && rec.rating >= 1 && rec.rating <= 5 ? rec.rating : null,
          remate_rated_at: rec?.updated_at || null,
        };
      };
      return {
        ...item,
        variants: Array.isArray(item.variants) && item.variants.length ? item.variants.map(tag) : item.variants,
        alternatives: Array.isArray(item.alternatives) ? item.alternatives.map((v,i) => tag({
          ...v, label: v.label || String.fromCharCode(65 + i),
          text: v.tweet_text || v.text || "",
          remate: v.remate || "",
        })) : item.alternatives,
      };
    }),
  };
}
export function buildTitularRemateRecord(item, variant, rating, now = new Date().toISOString()) {
  const n = Number(rating), key = titularRemateIdentity(item, variant);
  if (!key || !Number.isInteger(n) || n < 1 || n > 5) throw new Error("Remate o valoración no válida.");
  return {
    key, event_id: String(item.event_id), revision: Number(item.revision || 0),
    label: safeLabel(variant), title: String(item.title || "").trim(),
    factual_summary: String(item.factual_summary || "").trim(),
    tweet_text: String(variant.text || variant.tweet_text || "").trim(),
    remate: String(variant.remate || "").trim(), rating: n,
    created_at: now, updated_at: now, source: "ttittulares-listas-stars",
  };
}
