"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  EpisodeResolutionError, makeTrustedNewsIndex, makeTrustedTrendIndex,
  buildTrustedRelationIndexes, resolveValidatedPair
} = require("./resolve-exact-episodes.cjs");

const news = makeTrustedNewsIndex({
  processing: {items: [{
    id: "e1f64f5801b7", event_id: "e1f64f5801b7", revision: 1,
    status: "READY",
    title: "El perfil Un polaco de 24 años y con ideas de extrema derecha: así es el autor del ataque en Cracovia laSexta.com 07 de noviembre de 2026, 21:44"
  }]},
  status: {events: {
    "1e52f44e9612": {
      revision: 1, status: "ELIGIBLE",
      title: "Al menos seis muertos y doce heridos en un tiroteo en Cracovia, Polonia"
    }
  }}
});
const trends = makeTrustedTrendIndex({existing: [{
  id: "trend-cracovia", revision: 0, title: "Cracovia",
  episodeFingerprint: "server-issued-trend-fingerprint"
}]});
const make = (id = "e1f64f5801b7", revision = 1, fingerprint = null) => ({
  action: "link", commandId: "test-command-0001",
  expectedNews: {id, revision, episodeFingerprint: fingerprint},
  expectedTrend: {id: "trend-cracovia", revision: 0,
                  episodeFingerprint: "server-issued-trend-fingerprint"}
});

test("Cracovia's READY item from editorial-processing is linkable by exact ID/revision", () => {
  const resolved = resolveValidatedPair(make(), {news, trends});
  assert.equal(resolved.news.id, "e1f64f5801b7");
  assert.equal(resolved.news.revision, 1);
  assert.equal(resolved.trend.id, "trend-cracovia");
});

test("a second exact historical news episode is independently linkable", () => {
  const resolved = resolveValidatedPair(make("1e52f44e9612"), {news, trends});
  assert.equal(resolved.news.id, "1e52f44e9612");
});

test("does not filter valid archived episodes by Listas status, date or source", () => {
  assert.equal(news.size, 2);
  const other = makeTrustedNewsIndex({treated: {items: [
    {event_id: "old999abcde1", revision: 2, title: "Cracovia archivo",
     status: "treated", treated_at: "2025-01-01T00:00:00Z"}
  ]}});
  assert.equal(other.size, 1);
});

test("never creates a link by title alone or arbitrary client-provided episode", () => {
  assert.throws(
    () => resolveValidatedPair(make("totally-untrusted", 1), {news, trends}),
    err => err instanceof EpisodeResolutionError &&
           err.status === 409 && err.code === "episode_not_in_authoritative_catalog"
  );
});

test("rejects stale or altered revision and provided wrong fingerprint", () => {
  assert.throws(() => resolveValidatedPair(make("e1f64f5801b7", 0), {news, trends}),
    err => err.status === 409);
  assert.throws(() => resolveValidatedPair(make("e1f64f5801b7", 1, "unexpected-fp"),
    {news, trends}), err => err.status === 409);
});

test("keeps server-side fingerprint for previously linked historical episodes", () => {
  const catalog = makeTrustedNewsIndex({
    processing: {items: [{id: "e1f64f5801b7", revision: 1,
      title: "El perfil Un polaco de 24 años"}]},
    existing: [{id: "e1f64f5801b7", revision: 1,
      title: "Cracovia", episodeFingerprint: "real-server-fp"}]
  });
  assert.equal(catalog.get("e1f64f5801b7:r1").episodeFingerprint, "real-server-fp");
  const resolved = resolveValidatedPair(make("e1f64f5801b7", 1, "real-server-fp"),
    {news: catalog, trends});
  assert.equal(resolved.news.episodeFingerprint, "real-server-fp");
});

test("a mismatched trend fingerprint is rejected, not silently overwritten", () => {
  const decision = make();
  decision.expectedTrend.episodeFingerprint = "a-new-trend-fingerprint";
  assert.throws(() => resolveValidatedPair(decision, {news, trends}),
    err => err.status === 409 && err.code === "episode_fingerprint_conflict");
});

test("unlink preserves the exact identity validation", () => {
  const decision = make(); decision.action = "unlink";
  assert.equal(resolveValidatedPair(decision, {news, trends}).action, "unlink");
});

test("fail closed without trusted backend catalogs or command ID", () => {
  assert.throws(() => resolveValidatedPair(make(), {}), /Trusted catalogs missing/);
  const decision = make(); decision.commandId = "";
  assert.throws(() => resolveValidatedPair(decision, {news, trends}),
    err => err.status === 400);
});

test("the two real Cracovia news IDs remain independently selectable from trusted catalogs", () => {
  const indexes = buildTrustedRelationIndexes({
    processing: {items: [{
      id: "e1f64f5801b7", revision: 1, status: "READY",
      canonical_title: "El perfil Un polaco de 24 años y con ideas de extrema derecha: ataque en Cracovia"
    }]},
    status: {events: {
      "e1f64f5801b7": {revision: 1, title: "Perfil del autor en Cracovia"},
      "1e52f44e9612": {revision: 1, title: "Al menos cinco muertos en un tiroteo en Cracovia"}
    }},
    siteTop30: {items: [{
      editorial_id: "f4bdb3e1fe49", revision: 0, name: "Cracovia"
    }]}
  });
  const decision = id => ({
    action: "link", commandId: "cracovia-batch-test-0001",
    expectedNews: {id, revision: 1},
    expectedTrend: {id: "f4bdb3e1fe49", revision: 0}
  });
  assert.equal(resolveValidatedPair(decision("e1f64f5801b7"), indexes).news.id,
               "e1f64f5801b7");
  assert.equal(resolveValidatedPair(decision("1e52f44e9612"), indexes).news.id,
               "1e52f44e9612");
});

test("preserves fingerprints nested in existing Site relation items and endpoints", () => {
  const indexes = buildTrustedRelationIndexes({
    processing: {items: [{
      id: "e1f64f5801b7", revision: 1,
      canonical_title: "Primera noticia del ataque en Cracovia"
    }]},
    siteTop30: {items: [{
      editorial_id: "f4bdb3e1fe49", revision: 0, name: "Cracovia"
    }]},
    snapshot: {
      news: [{id:"e1f64f5801b7",revision:1,title:"Cracovia",
              episodeFingerprint:"authentic-news-fingerprint"}],
      items: [{news:{id:"e1f64f5801b7",revision:1,title:"Cracovia",
                      episodeFingerprint:"authentic-news-fingerprint"},
               trend:{id:"f4bdb3e1fe49",revision:0,title:"Cracovia",
                      episodeFingerprint:"authentic-trend-fingerprint"}}]
    }
  });
  const validated = resolveValidatedPair({
    action:"link",commandId:"existing-site-snapshot-0001",
    expectedNews:{id:"e1f64f5801b7",revision:1,
                  episodeFingerprint:"authentic-news-fingerprint"},
    expectedTrend:{id:"f4bdb3e1fe49",revision:0,
                   episodeFingerprint:"authentic-trend-fingerprint"}
  },indexes);
  assert.equal(validated.news.episodeFingerprint,"authentic-news-fingerprint");
  assert.equal(validated.trend.episodeFingerprint,"authentic-trend-fingerprint");
});

test("rejects forged fingerprint despite a valid historical ID and revision", () => {
  const indexes = buildTrustedRelationIndexes({
    snapshot: {
      news:[{id:"e1f64f5801b7",revision:1,title:"Cracovia",
             episodeFingerprint:"server-authentic"}],
      trends:[{id:"f4bdb3e1fe49",revision:0,title:"Cracovia",
               episodeFingerprint:"trend-authentic"}]
    }
  });
  assert.throws(() => resolveValidatedPair({
    action:"link",commandId:"fingerprint-conflict-001",
    expectedNews:{id:"e1f64f5801b7",revision:1,
                  episodeFingerprint:"forged-value"},
    expectedTrend:{id:"f4bdb3e1fe49",revision:0,
                   episodeFingerprint:"trend-authentic"}
  },indexes), err => err.status===409 && err.code==="episode_fingerprint_conflict");
});
