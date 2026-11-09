"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  EpisodeResolutionError, makeTrustedNewsIndex, makeTrustedTrendIndex,
  buildTrustedRelationIndexes, exposeLinkableEpisodes,
  resolveManualDecision, resolveValidatedPair
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


const julianCatalogs = {
  processing: {items: [{
    event_id: "9ed95352b91b", revision: 1, status: "READY",
    canonical_title: 'Enrique Cerezo: "El mejor perdón de Julián Álvarez no es un gol, sino dos"'
  }]},
  status: {events: {
    "9593c2b869f1": {
      revision: 1, status: "WAITING",
      title: 'El mensaje cariñoso de Simeone a Julián: "Lo necesitamos"'
    }
  }},
  siteTop30: {items: [{
    editorial_id: "trend-update-08da896cbbe389cf5192",
    revision: 0, name: "Julián", status: "EXPLICADA"
  }]}
};

const makeJulian = (id, commandId) => ({
  action: "link", commandId,
  expectedNews: {id, revision: 1},
  expectedTrend: {
    id: "trend-update-08da896cbbe389cf5192", revision: 0
  }
});

test("Julián: READY and WAITING are both eligible for manual linking, without extra restrictions", () => {
  for (const [id, cmd] of [
    ["9ed95352b91b", "julian-cerezo-unique-001"],
    ["9593c2b869f1", "julian-simeone-unique-001"]
  ]) {
    const resolved = resolveManualDecision(makeJulian(id, cmd), julianCatalogs);
    assert.equal(resolved.news.id, id);
    assert.equal(resolved.news.revision, 1);
    assert.equal(resolved.trend.id, "trend-update-08da896cbbe389cf5192");
    assert.equal(resolved.trend.revision, 0);
  }
});

test("all known exact episodes appear in the existing Site snapshot without inventing automatic links", () => {
  const indexes = buildTrustedRelationIndexes(julianCatalogs);
  const original = {items: [{
    id: "existing-nadal", state: "linked", origin: "manual",
    news: {id: "previous-news", revision: 1, title: "Nadal"},
    trend: {id: "previous-trend", revision: 0, title: "Nadal"}
  }], news: [], trends: []};
  const expanded = exposeLinkableEpisodes(original, indexes);
  assert.equal(expanded.items.length, 1);
  assert.equal(expanded.items[0].id, "existing-nadal");
  assert.deepEqual(expanded.news.map(x => x.id).sort(),
                   ["9593c2b869f1", "9ed95352b91b"].sort());
  assert.deepEqual(expanded.news.map(x => x.episodeFingerprint), ["", ""]);
  assert.equal(expanded.trends[0].id,
               "trend-update-08da896cbbe389cf5192");
  assert.equal(expanded.trends[0].episodeFingerprint, "");
  assert.equal(expanded.items.filter(x => x.trend?.id ===
    "trend-update-08da896cbbe389cf5192").length, 0);
});

test("Site readback preserves both independently saved links to Julián", () => {
  const indexes = buildTrustedRelationIndexes(julianCatalogs);
  const persistedItems = ["9ed95352b91b", "9593c2b869f1"].map((id, i) => ({
    id: "site-link-julian-" + i, state: "linked", origin: "manual",
    news: {id, revision: 1, episodeFingerprint: "site-issued-" + i,
           title: "Noticia Julián " + i, text: ""},
    trend: {
      id: "trend-update-08da896cbbe389cf5192",
      revision: 0, episodeFingerprint: "site-issued-trend-julian",
      title: "Julián", text: ""
    }
  }));
  const snapshot = {
    items: persistedItems,
    news: persistedItems.map(x => x.news),
    trends: [persistedItems[0].trend]
  };
  const expanded = exposeLinkableEpisodes(
    snapshot, buildTrustedRelationIndexes({...julianCatalogs, snapshot}));
  assert.equal(expanded.items.filter(x => x.state === "linked").length, 2);
  assert.equal(expanded.news.length, 2);
  assert.deepEqual(expanded.news.map(x => x.episodeFingerprint).sort(),
                   ["site-issued-0", "site-issued-1"]);
  assert.equal(expanded.trends[0].episodeFingerprint,
               "site-issued-trend-julian");
});

test("no editorial state filters, but an unknown ID or revision remains invalid", () => {
  assert.throws(() => resolveManualDecision(
    makeJulian("invented-news-id", "julian-invalid-news-001"),
    julianCatalogs
  ), error => error instanceof EpisodeResolutionError && error.status === 409);
  const wrong = makeJulian("9593c2b869f1", "julian-invalid-rev-001");
  wrong.expectedNews.revision = 3;
  assert.throws(() => resolveManualDecision(wrong, julianCatalogs),
    error => error.status === 409);
});

test("published historical news with a real ID/revision/title remains linkable", () => {
  const index = buildTrustedRelationIndexes({
    publicationEvents: {items: [{
      project: "ttittulares", event_id: "published-julian-001",
      revision: 4, title: "Julián, ya publicada", state: "sent"
    }]},
    siteTop30: julianCatalogs.siteTop30
  });
  assert.equal(index.news.get("published-julian-001:r4").title,
               "Julián, ya publicada");
  assert.equal(resolveValidatedPair({
    action: "link", commandId: "julian-published-test-001",
    expectedNews: {id: "published-julian-001", revision: 4},
    expectedTrend: {id: "trend-update-08da896cbbe389cf5192", revision: 0}
  }, index).news.id, "published-julian-001");
});
