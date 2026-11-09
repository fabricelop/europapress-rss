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
      project_id: "appgprj_6ae4dcf7d7488191a574e5b649e67370",
      images: [{
        target_id: "trendABC", revision: 0,
        explained_at: "2026-11-01T14:00:00Z", explanation: "Grouped fact",
        image_url: "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/trendABC-r0-" + sha.slice(0,12) + ".png",
        sha256: sha
      }]}
  }};
  const funcs = new Function("state", "isHttp",
    js.slice(first, last) +
    ";return {archivedPhoto,verifiedNewsAI,verifiedTrendSiteAI};");
  const {archivedPhoto, verifiedNewsAI, verifiedTrendSiteAI} = funcs(state, isHttp);
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
  assert.equal(verifiedTrendSiteAI({
    _kind: "tr", _status: "AGRUPADA", _id: "trendABC", revision: 0,
    explanation: "Grouped fact", explained_at: "2026-11-01T14:00:00Z"
  }), "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/trendABC-r0-" + sha.slice(0,12) + ".png",
    path + ": grouped trends keep normal verified AI");
  // Regression: manual editor-selected PNGs live on GitHub, not the Site's
  // own images host, and must be tied to an exact ID, revision and SHA.
  const trendCard = {_kind: "tr", _status: "EXPLICADA", _id: "trendABC",
    revision: 0, explanation: "Grouped fact", explained_at: "2026-11-01T14:00:00Z"};
  const manualURL = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/trendABC-r0-manual-" + sha.slice(0, 12) + ".png";
  state.data.trendSiteAi.images[0].image_url = manualURL;
  assert.equal(verifiedTrendSiteAI(trendCard), manualURL,
    path + ": manual original must render in expanded trend card");
  assert.equal(verifiedTrendSiteAI({...trendCard, _id: "otherTrend"}), "",
    path + ": must not mix different editorial IDs");
  assert.equal(verifiedTrendSiteAI({...trendCard, revision: 1}), "",
    path + ": must not mix different revisions");
  assert.equal(verifiedTrendSiteAI({...trendCard, explanation: "Changed episode"}), "",
    path + ": text mismatch must not show old art");
  state.data.trendSiteAi.images[0].image_url = manualURL.replace("-manual-", "-untrusted-");
  assert.equal(verifiedTrendSiteAI(trendCard), "",
    path + ": reject arbitrary GitHub PNG even with matching hash");
  state.data.trendSiteAi.images[0].image_url = manualURL.replace(
    "raw.githubusercontent.com", "example.com");
  assert.equal(verifiedTrendSiteAI(trendCard), "",
    path + ": reject other hosts");
  state.data.trendSiteAi.images[0].image_url = manualURL;

  // The full row is built with artwork OUTSIDE card-body. The Top 30
  // converter must reparent it BEFORE replaceChildren(), otherwise the
  // image disappears on expansion even when its URL is correct.
  const compactStart = js.indexOf("function compactTop30Card(out,x){");
  const compactEnd = js.indexOf("// X counts the trailing Site URL", compactStart);
  assert(compactStart > 0 && compactEnd > compactStart, path + ": compact function");
  function elem(tag) {
    return {tag, children: [], dataset: {}, classList: {add() {}},
      append(...nodes) {this.children.push(...nodes)},
      prepend(...nodes) {this.children.unshift(...nodes)},
      replaceChildren(...nodes) {this.children = nodes},
      querySelector() {return null},
      addEventListener() {},
      matches() {return false}};
  }
  const imageNode = elem("div");imageNode.className = "news-photo-set";
  imageNode.matches = selector => selector.includes(".news-photo-set");
  const body = elem("div");body.className = "card-body";
  const fact = elem("p");fact.matches = () => false;
  body.children = [fact];
  const card = elem("article");card.children = [imageNode, body];
  card.querySelector = selector => selector === ".card-body" ? body : null;
  const compact = new Function("document", "expandedTop30",
    "top30AgeBand", "stamp", "esc",
    js.slice(compactStart, compactEnd) + ";return compactTop30Card;")(
      {createElement: elem}, new Set(), () => "", x => x, x => x);
  const output = compact(card, {name: "Valverde", rank: 2,
    explanation: "Verified factual explanation", explained_at: ""});
  assert.equal(output.children[0].tag, "details",
    path + ": compact presentation is a details element");
  assert(output.children[0].children[1].children.includes(imageNode),
    path + ": expanded details preserve artwork from outside card-body");
  assert(html.includes(".card.trend-top .top30-expanded .pic{display:block"),
    path + ": expanded photo visible despite collapsed-card CSS");
  assert(html.includes("['EXPLICADA','AGRUPADA','CONJUNTA'].includes(x._status)"),
    path + ": grouped trends retain normal image actions");
  assert(html.includes("const archive=archivedPhoto(x);"), path + ": archive rendered");
  assert(html.includes("const pictureHTML=artwork?"), path + ": AI and archive rendered");
  assert(html.includes("<figcaption>Fotografía de archivo</figcaption>"), path + ": photo label");
  assert(html.includes("if(artwork)btn('Copiar imagen IA'"), path + ": AI copy action");
  assert(html.includes("shared/archive-photo-index.json"), path + ": archive index");
  console.log("TT_ACTUALIDAD_DUAL_IMAGE_WEB_OK " + path);
}
