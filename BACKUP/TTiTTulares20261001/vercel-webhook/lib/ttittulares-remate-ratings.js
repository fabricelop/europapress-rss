import crypto from "node:crypto";

function variantsOf(item) {
  if (Array.isArray(item?.variants) && item.variants.length) return item.variants;
  return (item?.alternatives || []).map((a, i) => ({
    ...a, label: a.label || String.fromCharCode(65 + i),
    text: a.tweet_text || a.text || "", remate: a.remate || "",
  }));
}
function safeLabel(v) { return String(v?.label || v?.name || "").trim().toUpperCase(); }
export function titularTweet(item) {
  if (item?.tweet && typeof item.tweet === "object") return {...item.tweet};
  const variants = variantsOf(item);
  const selected = variants.find(v => safeLabel(v) === "A") || variants.find(v => String(v?.remate || "").trim());
  return selected ? {...selected, text:selected.text || selected.tweet_text || ""} : null;
}
export function titularRemateIdentity(item, tweet = titularTweet(item)) {
  const eventId = String(item?.event_id || "").trim();
  const text = String(tweet?.text || tweet?.tweet_text || "").trim();
  const remate = String(tweet?.remate || "").trim();
  if (!eventId || !text || !remate.startsWith("🌶️ ")) return null;
  const revision = Number(item?.revision || 0);
  const digest = crypto.createHash("sha256")
    .update(JSON.stringify({ eventId, revision, text, remate }))
    .digest("hex").slice(0, 24);
  return `titular-remate-v2:${digest}`;
}
export function titularRemateVariants(item) {
  const tweet=titularTweet(item);
  return tweet?[tweet]:[];
}
export function annotateTitularRemates(prepared, ratings) {
  const byKey = new Map((ratings?.items || []).map(record => [record.key, record]));
  return {
    ...(prepared || {}),
    items: (prepared?.items || []).map(item => {
      const tweet=titularTweet(item);
      if(!tweet)return {...item,tweet:null};
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
        tweet:tag(tweet),
      };
    }),
  };
}
export function buildTitularRemateRecord(item, variant, rating, now = new Date().toISOString()) {
  const n = Number(rating), key = titularRemateIdentity(item, variant);
  if (!key || !Number.isInteger(n) || n < 1 || n > 5) throw new Error("Remate o valoración no válida.");
  return {
    key, event_id: String(item.event_id), revision: Number(item.revision || 0),
    title: String(item.title || "").trim(),
    factual_summary: String(item.factual_summary || "").trim(),
    tweet_text: String(variant.text || variant.tweet_text || "").trim(),
    remate: String(variant.remate || "").trim(), rating: n,
    created_at: now, updated_at: now, source: "ttittulares-listas-stars", schema_version: 2,
  };
}
