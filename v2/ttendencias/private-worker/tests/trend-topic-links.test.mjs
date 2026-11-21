import test from "node:test";
import assert from "node:assert/strict";
import {clearlySameTrendTopic as sameTopic} from "../src/trend-topic-links.js";

const row=(id,name,explanation)=>({trend_id:`trv2-${String(id).padStart(24,"0")}`,name,explanation});

test("PU groups two names referring to the same tennis final",()=>{
 const alcaraz=row(1,"Alcaraz","Alcaraz remonta ante Ben Shelton y alcanza la final de las ATP Finals en Turín.");
 const shelton=row(2,"Shelton","Carlos Alcaraz derrota a Shelton en la semifinal de las ATP Finals de Turín.");
 assert.equal(sameTopic(alcaraz,shelton),true);
 assert.equal(sameTopic(shelton,alcaraz),true);
});

test("PU does not group separate football matches merely sharing an opponent",()=>{
 const fulham=row(3,"Fulham","Fulham marca ante el Manchester City en el encuentro de la Premier League.");
 const arbeloa=row(4,"Arbeloa","Álvaro Arbeloa prepara el partido del Real Madrid ante Manchester City.");
 assert.equal(sameTopic(fulham,arbeloa),false);
});

test("PU accepts the same distinctive hashtag with typographic differences, never itself",()=>{
 const original=row(5,"#PortugueseGP","Se disputa el GP de Portugal de MotoGP.");
 const tagged=row(6,"PortugueseGP","Las motos compiten en el GP de Portugal.");
 assert.equal(sameTopic(original,tagged),true);
 assert.equal(sameTopic(original,original),false);
});

test("PU does not connect unrelated politics and festivals from generic words",()=>{
 const politics=row(7,"Feijóo","Feijóo interviene en el debate político y responde a Sánchez.");
 const festival=row(8,"Lorca","Lorca prepara su tradicional desfile medieval de San Clemente.");
 assert.equal(sameTopic(politics,festival),false);
});
