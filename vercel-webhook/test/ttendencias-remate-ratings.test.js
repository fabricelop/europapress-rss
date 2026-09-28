import test from "node:test";
import assert from "node:assert/strict";
import {
  annotateRemateRatings,
  buildRemateRatingRecord,
  remateRatingIdentity,
  remateText,
} from "../lib/ttendencias-remate-ratings.js";

const grouped = {
  name: "Luca Zidane",
  trend_names: ["Luca Zidane", "Suero"],
  revision: 0,
  explained_at: "2026-09-28T20:31:50Z",
  explanation: "Isra Suero marcó desde lejos. Le recetó una vaselina que no se vende en farmacias.",
  closer_text: "Le recetó una vaselina que no se vende en farmacias.",
};

test("el mismo grupo tiene una única identidad aunque cambie el orden", () => {
  assert.equal(remateRatingIdentity(grouped), remateRatingIdentity({
    ...grouped, name: "Suero", trend_names: ["Suero", "Luca Zidane"],
  }));
});

test("el texto y la revisión distinguen nuevas explicaciones y remates", () => {
  assert.notEqual(remateRatingIdentity(grouped), remateRatingIdentity({...grouped, revision: 1}));
  assert.notEqual(remateRatingIdentity(grouped), remateRatingIdentity({...grouped, explanation: grouped.explanation + " Otra frase."}));
  assert.equal(remateText(grouped), grouped.closer_text);
});

test("solo se aceptan valoraciones enteras del 1 al 5", () => {
  for (const n of [0, -1, 6, 2.5, "x", null]) assert.throws(() => buildRemateRatingRecord(grouped, n));
  assert.equal(buildRemateRatingRecord(grouped, 5).rating, 5);
});

test("la valoración se anota por explicación, no por navegador ni por nombre", () => {
  const record = buildRemateRatingRecord(grouped, 4, "2026-09-28T22:30:00Z");
  const later = {...grouped, revision: 1};
  const result = annotateRemateRatings({items:[grouped, later]}, {items:[record]});
  assert.equal(result.items[0].remate_rating, 4);
  assert.equal(result.items[0].rating_key, record.key);
  assert.equal(result.items[1].remate_rating, null);
});

test("el histórico puede identificar la última frase sin campo closer_text", () => {
  assert.equal(remateText({
    explanation: "El caso tiene puerta; el decreto aún busca llave.",
  }), "El caso tiene puerta; el decreto aún busca llave.");
});
