import crypto from "node:crypto";

export function normalizeTrendName(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("es-ES")
    .replace(/\s+/g, " ")
    .trim();
}

export function explanationTrendNames(item) {
  const values = [item?.name, ...(Array.isArray(item?.trend_names) ? item.trend_names : [])];
  for (const context of (Array.isArray(item?.trend_context) ? item.trend_context : [])) values.push(context?.name);
  const byNormalizedName = new Map();
  for (const value of values) {
    const name = String(value || "").trim();
    const normalized = normalizeTrendName(name);
    if (normalized && !byNormalizedName.has(normalized)) byNormalizedName.set(normalized, name);
  }
  return [...byNormalizedName.entries()]
    .sort(([left], [right]) => left.localeCompare(right, "es"))
    .map(([, name]) => name);
}

export function explanationCopyIdentity(item) {
  const group = explanationTrendNames(item).map(normalizeTrendName);
  const revision = Number.isFinite(Number(item?.revision)) ? Number(item.revision) : 0;
  const explainedAt = String(item?.explained_at || "").trim();
  const digest = crypto
    .createHash("sha256")
    .update(JSON.stringify({ group, revision, explained_at: explainedAt }))
    .digest("hex")
    .slice(0, 24);
  return `explanation-v1:${digest}`;
}

export function explanationIsCopied(item, copyState) {
  const key = explanationCopyIdentity(item);
  const records = copyState?.items || [];
  const record = records.find(entry => entry?.key === key);
  if (record) return { copied: true, copied_at: record.copied_at || null, source: record.source || "copy" };

  // Un mismo hecho puede reaparecer con más aliases del grupo y, por tanto,
  // con otra copy_key. Si el título editorial y la revisión coinciden, un
  // registro ya tratado se aplica a todo el grupo para que no "resucite".
  const groupTitle = normalizeTrendName(item?.group_title || "");
  const revision = Number.isFinite(Number(item?.revision)) ? Number(item.revision) : 0;
  if (groupTitle) {
    const groupRecord = records.find(entry =>
      normalizeTrendName(entry?.group_title || "") === groupTitle &&
      (Number.isFinite(Number(entry?.revision)) ? Number(entry.revision) : 0) === revision
    );
    if (groupRecord) return { copied: true, copied_at: groupRecord.copied_at || null, source: groupRecord.source || "group-copy" };
  }

  const explainedAt = Date.parse(item?.explained_at || "");
  const initializedThrough = Date.parse(copyState?.initialized_through || "");
  if (Number.isFinite(explainedAt) && Number.isFinite(initializedThrough) && explainedAt <= initializedThrough) {
    return { copied: true, copied_at: copyState.initialized_at || copyState.initialized_through, source: "initial-migration" };
  }
  return { copied: false, copied_at: null, source: null };
}

export function annotateExplainedCopyState(explained, copyState) {
  return {
    ...(explained || {}),
    items: (explained?.items || []).map(item => {
      const status = explanationIsCopied(item, copyState);
      return {
        ...item,
        copy_key: explanationCopyIdentity(item),
        copied: status.copied,
        copied_at: status.copied_at,
        copy_source: status.source,
      };
    }),
  };
}

export function buildCopyRecord(item, copiedAt = new Date().toISOString()) {
  return {
    key: explanationCopyIdentity(item),
    trend_names: explanationTrendNames(item),
    group_title: String(item?.group_title || "").trim() || null,
    explanation_group_id: String(item?.explanation_group_id || item?.group_id || "").trim() || null,
    revision: Number.isFinite(Number(item?.revision)) ? Number(item.revision) : 0,
    explained_at: String(item?.explained_at || "").trim() || null,
    copied_at: copiedAt,
    source: "copy-button",
  };
}
