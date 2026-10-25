import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {
  annotateExplainedCopyState,
  buildCopyRecord,
  explanationCopyIdentity,
  explanationIsCopied,
  sameEditorialEpisode,
} from "../lib/ttendencias-copy-state.js";

const grouped = {
  name: "Noruega",
  trend_names: ["Noruega", "Nyland"],
  revision: 2,
  explained_at: "2026-09-28T10:00:00Z",
};

test("la identidad es estable para un grupo aunque cambie el orden", () => {
  assert.equal(
    explanationCopyIdentity(grouped),
    explanationCopyIdentity({ ...grouped, name: "Nyland", trend_names: ["Nyland", "Noruega"] }),
  );
});

test("una revisión o reexplicación posterior obtiene otra identidad", () => {
  assert.notEqual(explanationCopyIdentity(grouped), explanationCopyIdentity({ ...grouped, revision: 3 }));
  assert.notEqual(
    explanationCopyIdentity(grouped),
    explanationCopyIdentity({ ...grouped, explained_at: "2026-10-01T11:00:00Z" }),
  );
});

test("la migración marca el histórico, pero deja pendientes las explicaciones futuras", () => {
  const explained = {
    items: [
      { ...grouped, explained_at: "2026-09-28T09:59:59Z" },
      { ...grouped, revision: 3, explained_at: "2026-09-28T10:00:01Z" },
    ],
  };
  const result = annotateExplainedCopyState(explained, {
    initialized_at: "2026-09-28T10:00:00Z",
    initialized_through: "2026-09-28T10:00:00Z",
    items: [],
  });
  assert.equal(result.items[0].copied, true);
  assert.equal(result.items[0].copy_source, "initial-migration");
  assert.equal(result.items[1].copied, false);
});

test("Copiar persiste la clave exacta y no marca otra revisión", () => {
  const record = buildCopyRecord(grouped, "2026-09-28T12:00:00Z");
  const result = annotateExplainedCopyState(
    { items: [grouped, { ...grouped, revision: 3 }] },
    { items: [record] },
  );
  assert.equal(result.items[0].copied, true);
  assert.equal(result.items[0].copied_at, "2026-09-28T12:00:00Z");
  assert.equal(result.items[1].copied, false);
});

test("un grupo ya tratado no resucita si después añade aliases", () => {
  const original = {
    name: "Los Reyes",
    trend_names: ["Los Reyes", "Ceuta y Melilla"],
    group_title: "Visita de los Reyes a Ceuta y Melilla el 13 y 14 de octubre",
    revision: 0,
    explained_at: "2026-10-01T10:53:30+02:00",
  };
  const expanded = {
    ...original,
    name: "#Melilla",
    trend_names: ["#Melilla", "Melilla", "Los Reyes", "Ceuta y Melilla"],
    explained_at: "2026-10-01T15:49:30+02:00",
  };
  const record = buildCopyRecord(original, "2026-10-01T14:40:32Z");
  const result = annotateExplainedCopyState({items:[expanded]},{items:[record]});
  assert.equal(result.items[0].copied,true);
});

test("Cancelo de octubre: un borrado y copia antiguos no archivan la explicación nueva", () => {
  const old = {
    id: "cd03f22f4fb4",name: "Cancelo",revision: 0,
    explained_at: "2026-10-04T22:23:30+02:00",
    group_title: "Cancelo empata para Portugal ante Noruega",
  };
  const fresh = {
    ...old,explained_at: "2026-10-26T00:01:19.419+01:00",
    group_title: "Cancelo · entrada a Diomande y polémica VAR",
  };
  const copy = buildCopyRecord(old, "2026-10-04T21:28:20Z");
  assert.equal(explanationIsCopied(old,{items:[copy]}).copied,true);
  assert.equal(explanationIsCopied(fresh,{items:[copy]}).copied,false);
  assert.equal(sameEditorialEpisode(fresh, {
    event_id: old.id,revision:0,status:"deleted",deleted_at:"2026-10-09T14:49:00Z"
  }),false);
  assert.equal(sameEditorialEpisode(fresh, {
    event_id: fresh.id,revision:0,status:"deleted",deleted_at:"2026-10-26T00:05:00+01:00"
  }),true);
});

test("la migración deja a cero todas las explicaciones existentes", () => {
  const explained = JSON.parse(fs.readFileSync(new URL("../../trends/telegram-manual-explained.json", import.meta.url), "utf8"));
  const copyState = JSON.parse(fs.readFileSync(new URL("../../trends/explained-copy-state.json", import.meta.url), "utf8"));
  const result = annotateExplainedCopyState(explained, copyState);
  assert.equal(result.items.length, explained.items.length);
  // Current trends intentionally reappear as fresh editorial episodes, even
  // when an old copy entry used the same ID/revision.
  const freshCancelo=result.items.find(x=>x.name==="Cancelo"&&
    String(x.explained_at||"").startsWith("2026-10-26"));
  if(freshCancelo)assert.equal(freshCancelo.copied,false);
});
