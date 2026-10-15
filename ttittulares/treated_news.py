#!/usr/bin/env python3
"""Durable, source-independent TTiTTulares identity guard.

A Telegram Borrar is a terminal *treated* decision (publication unknown), not a
license to recreate the story with a different RSS URL or event_id. All stages
read the same retained identities. Never delete somebody's other card here.
"""
from __future__ import annotations
import json
import re
import unicodedata
from datetime import datetime, timezone, timedelta
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

ROOT=Path(__file__).resolve().parents[1]
CLOSED={"deleted","dismissed","published","treated"}
STOP=set("de del la las el los un una unos unas y o en a por para con sin sobre que se su sus al es tras ante como mas ya hoy este esta estos estas lo le les entre desde hacia durante despues antes segun sera fueron fue sigue acerca noticia noticias directo ultima hora".split())
ALIAS={
 "fallece":"morir","fallecio":"morir","muere":"morir","murio":"morir","muerte":"morir",
 "denuncias":"denuncia","denunciadas":"denuncia","denunciado":"denuncia",
 "exigen":"exigir","exige":"exigir","urge":"exigir","pide":"exigir",
 "suspendido":"suspension","suspende":"suspension","suspension":"suspension",
 "ciberataques":"ciberataque","hackea":"ciberataque","hackean":"ciberataque",
 "detenidos":"detenido","detenidas":"detenido",
 "heridos":"herido","herida":"herido",
 "policias":"policia","ultras":"ultra","supuestas":"presunta","supuesta":"presunta",
 "mantiene":"mantener","mantenido":"mantener",
 "marroquies":"marroqui","buques":"buque",
 "reyes":"rey","actores":"actor",
 "hungaro":"hungria","hungara":"hungria","hungaros":"hungria","hungaras":"hungria",
 "relaciona":"vincular","relacionaba":"vincular","relaciono":"vincular",
 "vincula":"vincular","vinculaba":"vincular","vinculo":"vincular",
 # Variantes reales del mismo hecho publicadas por distintas fuentes.
 "roban":"robo","robado":"robo","robada":"robo","robar":"robo",
 "filtraciones":"filtracion","filtrados":"filtracion","filtrada":"filtracion",
 "investiga":"investigar","investigan":"investigar","investigacion":"investigar",
 "reabre":"reabrir","reabren":"reabrir","reapertura":"reabrir",
 "sancionador":"sancion","sancionadora":"sancion",
 "retransmision":"emision","transmision":"emision",
 "transmitida":"emision","transmitido":"emision","retransmitida":"emision",
 "retransmitido":"emision","retransmitir":"emision","transmitir":"emision",
 "streaming":"emision","fusilamiento":"ejecucion",
 "conversaciones":"mensaje","mensajes":"mensaje",
}
def load(path,default):
    try:
        return json.loads((ROOT/path).read_text(encoding="utf8"))
    except (OSError,ValueError,TypeError):
        return default

def normalize(text):
    v=unicodedata.normalize("NFKD",str(text or "").casefold())
    v="".join(c for c in v if not unicodedata.combining(c))
    # Strip common feed prefixes and dates from publisher descriptions.
    v=re.sub(r"\b(?:en directo|ultima hora|video|actualizado)\b"," ",v)
    # El condenado de Fort Hood y Nidal Hasan identifican el mismo suceso.
    v=re.sub(r"\b(?:fort hood|nidal hasan)\b"," nidal hasan fort hood ",v)
    return " ".join(re.findall(r"[a-z0-9]+",v))

def tokens(title):
    return set(ALIAS.get(x,x) for x in normalize(title).split()
               if (len(x)>2 or x in {"pp","ue","rj"}) and x not in STOP)

def comparable_url(url):
    try:
        p=urlsplit(str(url or ""))
        return urlunsplit((p.scheme.lower(),p.netloc.lower(),p.path.rstrip("/"),"","")) if p.netloc else ""
    except ValueError:
        return ""

def event_stage(title):
    """A later *action* is not the same fact just because names/topic coincide.

    Only distinguish explicit, verifiable proceedings here. Mere reports about
    an incident do not inherit the subsequent act of sending it to the court.
    """
    t=tokens(title)
    if ({"justicia","fiscalia","juzgado","tribunal"} & t and
            {"envia","remite","remiten","traslada","trasladan","entrega","entregan"} & t):
        return "remitido_justicia"
    return ""

def same_fact(a,b):
    """Conservative concrete-fact similarity, never topic-only similarity."""
    left,right=(a or {}),(b or {})
    urls_a={comparable_url(v) for v in ([left.get("url"),left.get("source_url")]+list(left.get("source_urls") or []))}
    urls_b={comparable_url(v) for v in ([right.get("url"),right.get("source_url")]+list(right.get("source_urls") or []))}
    if (urls_a- {""}) & (urls_b- {""}): return True
    names_a=[str(x) for x in ([left.get("title") or left.get("canonical_title")]+list(left.get("aliases") or [])) if x]
    names_b=[str(x) for x in ([right.get("title") or right.get("canonical_title")]+list(right.get("aliases") or [])) if x]
    for a_title in names_a[:12]:
        A=tokens(a_title)
        if len(A)<3:continue
        for b_title in names_b[:12]:
            # A documented later referral is a distinct editorial development.
            if event_stage(a_title)!=event_stage(b_title):continue
            B=tokens(b_title)
            if len(B)<3:continue
            common=A&B
            if len(common)<3:continue
            # Rechazar/archivar frente a abrir/incoar son decisiones opuestas,
            # no meras paráfrasis: no bloquear una novedad contradictoria.
            opposite={"rechaza","desestima","archiva","cierra","revoca"}
            opening={"abre","abrir","incoa","iniciar"}
            if ((A & opposite and B & opening) or
                    (B & opposite and A & opening)):
                continue
            overlap=len(common)/min(len(A),len(B))
            jac=len(common)/len(A|B)
            likeness=SequenceMatcher(None,normalize(a_title),normalize(b_title)).ratio()
            concrete_actions={"morir","suspension","ciberataque","denuncia","exigir",
                              "dimision","detenido","policia","disparo","incendio","asalto",
                              "sentencia","accidente","rescate","vincular",
                              "robo","investigar","filtracion","reabrir","ejecucion",
                              "emision","sancion"}
            anchored=bool(common & concrete_actions)
            if (A==B or (len(common)>=4 and overlap>=.69 and jac>=.40)
                    or (anchored and len(common)>=5 and overlap>=.48 and jac>=.28)
                    or (len(common)>=3 and overlap>=.79 and jac>=.52)
                    or (len(common)>=3 and likeness>=.84 and overlap>=.56)):
                return True
    return False

def eligible_reference(row,now=None):
    """Recent delivery; terminal memory persists for 180 days, not forever."""
    now=now or datetime.now(timezone.utc)
    date=row.get("delivered_at") or row.get("treated_at") or row.get("processed_at")
    if not date:return True
    try:
        dt=datetime.fromisoformat(str(date).replace("Z","+00:00"))
        if dt.tzinfo is None:dt=dt.replace(tzinfo=timezone.utc)
        return now-dt <= timedelta(days=180)
    except (ValueError,TypeError):
        return True

def references(deliveries=None,treated=None,decisions=None):
    """Telegram acknowledgements + durable decisions; no status inference from URLs."""
    deliveries=deliveries if deliveries is not None else load("telegram/ttittulares-deliveries.json",{"items":[]})
    treated=treated if treated is not None else load("ttittulares/treated-stories.json",{"items":[]})
    decisions=decisions if decisions is not None else load("ttittulares/decisions.json",{"items":[]})
    closed={str(r.get("event_id") or "") for r in decisions.get("items",[])
            if str(r.get("status") or "").lower() in CLOSED}
    seen=set()
    for row in list(treated.get("items",[]))+list(deliveries.get("items",[])):
        if not isinstance(row,dict):continue
        eid=str(row.get("event_id") or "")
        status=str(row.get("status") or "").lower()
        if (not eid or not (status in CLOSED or status=="sent" or eid in closed)
                or not eligible_reference(row)):continue
        if not (row.get("title") or row.get("canonical_title")):continue
        key=(eid,str(row.get("title") or row.get("canonical_title")))
        if key in seen:continue
        seen.add(key)
        yield row

def previous_story(row,refs,ignore_id=None):
    eid=str(row.get("event_id") or row.get("id") or "")
    ignore_id=str(ignore_id or "")
    for ref in refs:
        old_id=str(ref.get("event_id") or "")
        if old_id and old_id==ignore_id:continue
        if old_id and old_id==eid:return ref
        if same_fact(row,ref):return ref
    return None

def merge_treated(history,decision_rows,delivery_rows,at):
    """Append-only compact identity archive, closed only by an explicit decision."""
    previous=list(history.get("items") or [])
    lookup={}
    for row in delivery_rows:
        eid=str(row.get("event_id") or "")
        if eid and (row.get("title") or row.get("name")):
            lookup.setdefault(eid,[]).append(row)
    by_id={str(x.get("event_id") or ""):x for x in previous if x.get("event_id")}
    for row in decision_rows:
        eid=str(row.get("event_id") or "")
        status=str(row.get("status") or "").lower()
        if not eid or status not in CLOSED:continue
        titles=lookup.get(eid) or []
        old=by_id.get(eid)
        if not titles and not old:continue
        title=(titles[-1].get("title") or titles[-1].get("name")) if titles else old.get("title")
        if not title:continue
        item=old if old is not None else {"event_id":eid,"title":title}
        item["status"]="treated"
        item["disposition"]=(status if status in {"published","dismissed"} else "unspecified")
        item["treated_at"]=item.get("treated_at") or row.get("updated_at") or at
        if titles:
            urls=list(dict.fromkeys(str(t.get("source_url") or "") for t in titles if t.get("source_url")))
            item["source_urls"]=list(dict.fromkeys(list(item.get("source_urls") or [])+urls))[:12]
        by_id[eid]=item
    history["version"]=1
    history["updated_at"]=at
    history["items"]=list(by_id.values())
    history["count"]=len(history["items"])
    return history

def selftest():
    p=lambda title:{"title":title}
    assert same_fact(p("El Supremo mantiene la suspensión del voto por la ley de nietos"),
                     p("El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"))
    assert same_fact(p("Muere RJ Mitte, el actor de Breaking Bad a los 34 años"),
                     p("Fallece el actor RJ Mitte, hijo de Walter White en Breaking Bad, a los 34 años"))
    assert same_fact(p("Un ciberataque estropea alimentos frescos de supermercados de Francia"),
                     p("Un ciberataque hackea la refrigeración y estropea productos frescos de supermercados de Francia"))
    assert same_fact(
        p("Un ciberataque estropea los alimentos frescos y congelados de varios supermercados de Francia y deja pérdidas millonarias"),
        p("Un ciberataque hackea los sistemas de refrigeración y estropea los productos frescos de cientos de supermercados en Francia"))
    assert same_fact(
        p("El PP de Cádiz exige la dimisión del alcalde de Algeciras tras conocer una nueva denuncia de agresión sexual"),
        p("El PP urge la dimisión del alcalde de Algeciras tras las denuncias de dos afiliadas por supuesta agresión sexual"))
    assert same_fact(
        p("El Supremo mantiene la suspensión del derecho a voto de los nacionalizados por la ley de nietos"),
        p("El Supremo mantiene la suspensión del derecho a voto de los nacionalizados por la ley de nietos"))
    assert same_fact(
        p("El Parlamento húngaro enmienda la ley de 2021 que vinculaba la homosexualidad con la pederastia"),
        p("Hungría deroga la ley de Orbán que vinculaba pederastia y homosexualidad e impedía hablar de LGTBIQ+ en las escuelas"))
    assert same_fact(
        p("Hungría anula la ley de Orbán que relacionaba la homosexualidad con la pederastia"),
        p("Hungría deroga la ley de Orbán que vinculaba pederastia y homosexualidad e impedía hablar de LGTBIQ+ en las escuelas"))
    assert not same_fact(
        p("Hungría deroga la ley de Orbán que vinculaba pederastia y homosexualidad"),
        p("El Parlamento húngaro aprueba una ley de vivienda para familias"))
    assert not same_fact(p("El Gobierno estudia recurrir al Constitucional el fallo del Supremo por la ley de nietos"),
                         p("El Supremo mantiene suspendido el voto de los nacionalizados por la ley de nietos"))
    assert not same_fact(p("Los reyes visitan Ceuta y Melilla"),
                         p("Marruecos critica la visita de los reyes a Ceuta y Melilla"))
    # Paráfrasis reales del 15/10: una sola noticia pese a IDs diferentes.
    duplicate_pairs=[
        ("Trump cambia de opinión y dice que el fusilamiento del condenado por el ataque de Fort Hood no será retransmitido en streaming",
         "Trump dice que la ejecución de Nidal Hasan no será transmitida en directo"),
        ("Trump cambia de opinión y dice que el fusilamiento del condenado por el ataque de Fort Hood no será retransmitido en streaming",
         "Trump cancela la transmisión en directo de la ejecución de Nidal Hasan"),
        ("Roban en la casa de Antony durante el Betis-Oporto",
         "Antony, víctima de un robo en su casa durante el Betis - Oporto"),
        ("El Supremo ordena reabrir la causa contra Natividad Jáuregui por un atentado",
         "El Supremo ordena reabrir una causa contra Natividad Jáuregui, la etarra de las mariscadas"),
        ("La Junta Electoral abre expediente sancionador a Sánchez por una rueda de prensa en La Moncloa",
         "La Junta Electoral abre expediente sancionador a Pedro Sánchez por la rueda de prensa en La Moncloa"),
        ("Un juzgado de Madrid investiga las filtraciones de conversaciones personales de Zapatero",
         "Un juzgado de Madrid investiga la filtración de mensajes personales de Zapatero"),
    ]
    for first,second in duplicate_pairs:
        assert same_fact(p(first),p(second)),(first,second)
    # No fusionar nueva decisión, persona distinta ni un paso judicial nuevo.
    assert not same_fact(p("La Junta Electoral abre expediente sancionador a Sánchez por la rueda de prensa en La Moncloa"),
                         p("La Junta Electoral rechaza investigar a Sánchez por la rueda de prensa en La Moncloa"))
    assert not same_fact(p("Trump dice que la ejecución de Nidal Hasan no será retransmitida en directo"),
                         p("Trump dice que la ejecución de otro condenado no será retransmitida en directo"))
    assert not same_fact(p("Militares de Ceuta aparecen en audios sobre agresiones a migrantes"),
                         p("Defensa envía a la Justicia los audios de militares de Ceuta sobre agresiones a migrantes"))
    refs=[{"event_id":"old","title":"El Supremo mantiene la suspensión del voto por la ley de nietos","status":"treated"}]
    assert previous_story({"event_id":"new","title":"El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"},refs)["event_id"]=="old"
    h=merge_treated({"items":[]},[{"event_id":"x","status":"deleted"}],
                    [{"event_id":"x","title":"Noticia tratada por Telegram"}],"2026-10-13T06:00:00Z")
    assert h["items"][0]["disposition"]=="unspecified"
    print("TTITTULARES_TREATED_NEWS_SELFTEST_OK")

if __name__=="__main__":
    selftest()
