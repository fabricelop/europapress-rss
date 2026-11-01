"use strict";
// Offline regression checks for both TTActualidad web editors.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const paths = ["pilot/ttactualidad-live/index.html", "docs/ttactualidad/index.html"];
const id = "newsABC";
const sha = "a".repeat(64);
const url = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/" + id + "-r1-manual-" + sha.slice(0, 12) + ".png";
const archive = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/archive-images/" + id + "-r1-abcdef.jpg";
const trendArchive = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/archive-images/trendABC-r0-abcdef.jpg";
const isHttp = raw => {
  try { const u = new URL(raw); return u.protocol === "https:" ? u.href : ""; }
  catch { return ""; }
};

for (const path of paths) {
  const html = fs.readFileSync(path, "utf8");
  const start = html.indexOf("<script>"), end = html.lastIndexOf("</script>");
  assert(start > 0 && end > start, path + ": script");
  const js = html.slice(start + "<script>".length, end);
  new Function(js);
  const first = js.indexOf("function archivedPhoto(x)");
  const last = js.indexOf("function imageWorkflowPrompt(x,associationOnly=false)", first);
  assert(first > 0 && last > first, path + ": resolvers");
  const state = {data: {
    archiveIndex: {schema_version: 1, kind: "archive_only", photos: {
      "ttittulares:newsABC:r1": archive,
      "ttendencias:trendABC:r0": trendArchive
    }},
    newsAi: {schema_version: 1, project: "ttittulares", images: [{
      target_id: id, revision: 1, prepared_at: "2026-11-01T16:00:00Z",
      editorial_text: "Original factual news", image_url: url, sha256: sha
    }]},
    trendSiteAi: {schema_version: 1,
      project_id: "appgprj_6ae4dcf7d7488191a574e5b649e67370", images: []}
  }};
  const funcs = new Function("state", "isHttp",
    js.slice(first, last) +
    ";return {archivedPhoto,verifiedNewsAI,verifiedTrendSiteAI};");
  const {archivedPhoto, verifiedNewsAI} = funcs(state, isHttp);
  const original = {_kind: "tti", _status: "LISTA", event_id: id,
    revision: 1, prepared_at: "2026-11-01T16:00:00Z",
    tweet: {text: "Original factual news"}};
  assert.equal(verifiedNewsAI(original), url, path + ": original AI");
  assert.equal(archivedPhoto(original), archive, path + ": original archive");
  assert.equal(verifiedNewsAI({...original, prepared_at: "2026-11-01T17:00:00Z",
    tweet: {text: "Editorial correction"} }), url,
    path + ": same ID and revision preserves original after textual edit");
  const edited = {...original, revision: 2,
    prepared_at: "2026-11-02T17:00:00Z",
    tweet: {text: "Updated factual news"}};
  assert.equal(verifiedNewsAI(edited), url, path + ": AI retained by event ID");
  assert.equal(archivedPhoto(edited), archive, path + ": archive retained by event ID");
  // TTImages outbox stores a hash-verified file as -ai<attempt>.jpg (without
  // the hash in the filename). The manifest carries the SHA-256.
  const pipelineURL = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/newsABC-r1-ai1.jpg";
  state.data.newsAi.images[0].image_url = pipelineURL;
  assert.equal(verifiedNewsAI(edited), pipelineURL,
    path + ": TTImages outbox original survives revision");
  state.data.newsAi.images[0].image_url = url;
  assert.equal(verifiedNewsAI({...edited, event_id: "otherNews"}), "",
    path + ": no cross-ID AI");
  assert.notEqual(archivedPhoto({...edited, event_id: "otherNews"}), archive,
    path + ": no cross-ID archive");
  assert.equal(verifiedNewsAI({...original, rewrite_pending: true}), "",
    path + ": rewrite pending image blocked");
  assert.equal(archivedPhoto({_kind: "tr", _id: "trendABC", revision: 0}),
    trendArchive, path + ": trend archive");
  assert(html.includes("const archive=archivedPhoto(x);"), path + ": archive rendered");
  assert(html.includes("const pictureHTML=artwork?"), path + ": AI and archive rendered");
  assert(html.includes("<figcaption>Fotografía de archivo</figcaption>"), path + ": photo label");
  assert(html.includes("if(artwork)btn('Copiar imagen IA'"), path + ": AI copy action");
  assert(html.includes("shared/archive-photo-index.json"), path + ": archive index");
  console.log("TT_ACTUALIDAD_DUAL_IMAGE_WEB_OK " + path);
}
