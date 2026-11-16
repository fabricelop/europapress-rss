#!/usr/bin/env python3
"""Conservative, pure headline grouping and source-family consensus for news V2."""
from __future__ import annotations
import hashlib
import re
import unicodedata
from difflib import SequenceMatcher
from itertools import combinations
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

STOP=set("a al algo ante bajo con contra de del desde el ella en entre era es esta este esto ha hay la las lo los mas muy no o para pero por que se sin sobre su sus un una y ya".split())
TOKEN_ALIASES={
 "fronteras":"frontera","fronterizo":"frontera","fronteriza":"frontera","fronterizos":"frontera","fronterizas":"frontera",
 "pide":"pedir","pidio":"pedir","pedido":"pedir","pidiendo":"pedir","solicita":"pedir","solicito":"pedir","pedir":"pedir",
 "explicaciones":"explicacion","respuesta":"explicacion","respuestas":"explicacion",
 "falla":"fallar","fallo":"fallar","fallido":"fallar","fallida":"fallar","fallaron":"fallar",
 "detenido":"detener","detenida":"detener","detencion":"detener","detenciones":"detener",
 "muere":"morir","murio":"morir","muerto":"morir","muerta":"morir","fallece":"morir","fallecio":"morir","fallecido":"morir","fallecida":"morir",
 "cerrada":"cerrar","cerrado":"cerrar","cierra":"cerrar","cierre":"cerrar",
 "sanidad":"salud","australiana":"australia","australiano":"australia","australianas":"australia","australianos":"australia",
 "autorizacion":"permiso","autorizado":"permiso","autorizada":"permiso","accede":"acceder","accedio":"acceder","hackeo":"acceder","hackear":"acceder","cuela":"acceder","colarse":"acceder",
 "palestine":"palestina","tour":"gira","tours":"gira","cazas":"caza","drones":"dron",
 "espanoles":"espanol","espanola":"espanol","espanolas":"espanol","espaoles":"espanol","espaola":"espanol",
 "rumana":"rumania","rumano":"rumania","rusos":"ruso","rusa":"ruso","rusas":"ruso",
 "malagueno":"malaga","malaguena":"malaga","confinado":"confinar","confinada":"confinar","confinamiento":"confinar",
 "confinan":"confinar","moviliza":"movilizar","movilizan":"movilizar","movilizado":"movilizar","movilizados":"movilizar",
 "activa":"activar","activan":"activar","despliega":"desplegar","despliegan":"desplegar",
 "fallece":"morir","denuncias":"denuncia","denunciadas":"denuncia","denunciado":"denuncia","denunciadas":"denuncia",
 "exigen":"exigir","exige":"exigir","urge":"exigir","suspendido":"suspension","suspende":"suspension",
 "ciberataques":"ciberataque","hackea":"ciberataque","hackean":"ciberataque","detenidos":"detenido","detenidas":"detenido",
 "heridos":"herido","herida":"herido","policias":"policia","ultras":"ultra","supuestas":"presunta","supuesta":"presunta",
 "mantiene":"mantener","mantenido":"mantener","marroquies":"marroqui","buques":"buque","reyes":"rey","actores":"actor",
 "hungaro":"hungria","hungara":"hungria","hungaros":"hungria","hungaras":"hungria","relaciona":"vincular","relacionaba":"vincular",
 "relaciono":"vincular","vincula":"vincular","vinculaba":"vincular","vinculo":"vincular","roban":"robo","robado":"robo",
 "robada":"robo","robar":"robo","filtraciones":"filtracion","filtrados":"filtracion","filtrada":"filtracion",
 "investiga":"investigar","investigan":"investigar","investigacion":"investigar","reabre":"reabrir","reabren":"reabrir",
 "reapertura":"reabrir","sancionador":"sancion","sancionadora":"sancion","retransmision":"emision","transmision":"emision",
 "transmitida":"emision","transmitido":"emision","retransmitida":"emision","retransmitido":"emision","retransmitir":"emision",
 "transmitir":"emision","streaming":"emision","fusilamiento":"ejecucion"
}
EVENT_ACTION_ALIASES={
 "reunion":"reunion","reunirse":"reunion","reunen":"reunion","reune":"reunion","encuentro":"reunion","entrevista":"reunion",
 "cumbre":"reunion","recibe":"reunion","recibir":"reunion","visita":"reunion","recibimiento":"reunion",
 "firmar":"acuerdo","firma":"acuerdo","acuerdo":"acuerdo","pacto":"acuerdo","demandar":"demanda","demanda":"demanda",
 "denunciar":"denuncia","denuncia":"denuncia","detener":"detencion","arresto":"detencion","morir":"muerte","fallecer":"muerte",
 "dimitir":"dimision","dimite":"dimision","renunciar":"dimision","renuncia":"dimision","cese":"dimision","cesar":"dimision",
 "relevo":"dimision","abandona":"dimision","abandonar":"dimision","ganar":"victoria","gana":"victoria","vencer":"victoria",
 "vence":"victoria","perder":"derrota","pierde":"derrota","derrota":"derrota","aprobar":"aprobacion","aprueba":"aprobacion",
 "avalar":"aprobacion","avala":"aprobacion","prohibir":"prohibicion","prohibe":"prohibicion","vetar":"prohibicion",
 "veta":"prohibicion","movilizar":"movilizacion","desplegar":"movilizacion","confinar":"confinamiento"
}
PROPER_GENERIC={"nueva","york","estados","unidos","casa","blanca","onu","europa","espana","gobierno","congreso","senado"}
GENERIC_MATCH=set("""
morir hombre mujer persona personas anos herido herida heridos heridas incendio forestal
detener detenido detenida caer tres dos uno noticia ultima directo crisis actualidad
nueva york reunion encuentro reunir reunirse delegacion
""".split())
MATERIAL_TOKENS=set("""
muere muerto fallece fallecido dimite dimision detenido detencion sentencia condena absuelto absuelve
gana ganador pierde derrota confirma confirmado acuerdo aprueba aprobado cancela cancelado rompe ruptura
rescata rescatado desaparecido encontrado hospitalizado alta cesado cese nombrado nombramiento
""".split())


def normalize(value):
    text="".join(c for c in unicodedata.normalize("NFKD",str(value or "").casefold())
                 if not unicodedata.combining(c))
    text=re.sub(r"\b(?:en directo|ultima hora|video|actualizado)\b"," ",text)
    text=re.sub(r"\bf\s*[- ]\s*18\b","f18",text)
    return " ".join(re.findall(r"[a-z0-9]+",text))


def tokens(value):
    out=[]
    for token in normalize(value).split():
        token=TOKEN_ALIASES.get(token,token)
        if (len(token)>2 or token in {"pp","ue","rj"}) and token not in STOP:
            out.append(token)
    return set(out)


def fingerprint(value):
    return frozenset(tokens(value))


def event_actions(value):
    result={EVENT_ACTION_ALIASES[t] for t in tokens(value) if t in EVENT_ACTION_ALIASES}
    raw=tokens(value)
    if "activar" in raw and ({"caza","f18","fuerza","avion"} & raw):
        result.add("movilizacion")
    return result


def proper_tokens(value):
    out=set()
    for raw in re.findall(r"\b[A-ZÁÉÍÓÚÜÑ][A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{1,}\b",str(value or "")):
        token=normalize(raw)
        token=TOKEN_ALIASES.get(token,token)
        if token not in STOP and token not in PROPER_GENERIC and token not in GENERIC_MATCH:
            out.add(token)
    return out


def same_event_semantic(a,b):
    common=proper_tokens(a)&proper_tokens(b)
    distinctive=(fingerprint(a)&fingerprint(b))-GENERIC_MATCH
    actions=event_actions(a)&event_actions(b)
    if len(common)>=2 and actions:
        return True
    if len(common)>=2 and len(distinctive)>=3:
        return True
    if len(common)>=1 and actions and len(distinctive)>=3:
        return True
    if len(common)>=1 and len(distinctive)>=5:
        return True
    return False


def title_score(a,b):
    left,right=fingerprint(a),fingerprint(b)
    if not left or not right:
        return 0.0
    common=left&right
    inter=len(common)
    if inter<2:
        return 0.0
    distinctive=common-GENERIC_MATCH
    if min(len(left),len(right))>=5 and len(distinctive)<2:
        return 0.0
    overlap=inter/max(1,min(len(left),len(right)))
    jaccard=inter/max(1,len(left|right))
    if min(len(left),len(right))<=4 and overlap<0.60:
        return 0.0
    if inter==2 and overlap<0.80:
        return 0.0
    if overlap<0.65 and jaccard<0.35:
        return 0.0
    return 0.55*overlap+0.45*jaccard


def title_match_value(a,b):
    value=title_score(a,b)
    return max(value,0.72) if same_event_semantic(a,b) else value


def titles_match(a,b,threshold=0.50):
    return title_match_value(a,b)>=threshold


def best_match(title,events,threshold=0.50):
    best=None
    best_score=0.0
    for event in events:
        canonical=event.get("canonical_title") or event.get("title") or ""
        canonical_score=title_match_value(title,canonical)
        variants=[a.get("title","") for a in event.get("appearances",[]) if a.get("title")][-8:]
        scores=[title_match_value(title,v) for v in variants]
        hits=[value for value in scores if value>=threshold]
        if len(scores)>=3 and canonical_score<threshold and len(hits)<2:
            score=0.0
        else:
            score=max([canonical_score]+scores+[0.0])
        if score>best_score:
            best,best_score=event,score
    return (best,best_score) if best and best_score>=threshold else (None,best_score)


def evidence_title_eligible(title):
    all_tokens=fingerprint(title)
    distinctive=all_tokens-GENERIC_MATCH
    lowered=" ".join(normalize(title).split())
    return (len(all_tokens)>=5 and len(distinctive)>=3
            and not lowered.startswith(("portada ","noticias ","guerra ")))


def source_family(source,catalog):
    row=(catalog.get("source_map") or {}).get(str(source or ""))
    return row.get("family",str(source)) if row else str(source or "")


def has_independent_evidence_consensus(appearances,catalog,min_families=4):
    rows=[a for a in appearances or []
          if a.get("source_type")=="general" and a.get("source")
          and evidence_title_eligible(a.get("title",""))]
    if len({source_family(a["source"],catalog) for a in rows})<min_families:
        return False
    for group in combinations(rows,min_families):
        if len({source_family(a["source"],catalog) for a in group})!=min_families:
            continue
        edges=[]
        degree=[0]*len(group)
        for i,j in combinations(range(len(group)),2):
            if titles_match(group[i].get("title",""),group[j].get("title","")):
                edges.append((i,j))
                degree[i]+=1
                degree[j]+=1
        if len(edges)>=min_families:
            return True
        if len(edges)==min_families-1 and max(degree,default=0)==min_families-1:
            shared=set.intersection(*(set(fingerprint(a.get("title","")))-GENERIC_MATCH for a in group))
            if any(len(token)>=5 for token in shared):
                return True
    return False


def choose_representative_title(event):
    appearances=[a for a in event.get("appearances",[]) if a.get("title")]
    if len(appearances)<2:
        return
    best=None
    for row in appearances:
        support=0
        strength=0.0
        for other in appearances:
            if row is other:
                continue
            value=title_score(row.get("title",""),other.get("title",""))
            semantic=same_event_semantic(row.get("title",""),other.get("title",""))
            if value>=0.50 or semantic:
                support+=1
                strength+=max(value,0.72 if semantic else 0.0)
        key=(support,round(strength,4),len(row.get("title","")))
        if best is None or key>best[0]:
            best=(key,row)
    if best and best[0][0]>=1:
        event["canonical_title"]=best[1]["title"]
        if best[1].get("url"):
            event["canonical_url"]=best[1]["url"]


def recalc_event_sources(event,catalog):
    appearances=event.get("appearances") or []
    general=sorted({a["source"] for a in appearances if a.get("source_type")=="general"})
    sport=sorted({a["source"] for a in appearances if a.get("source_type")=="sport"})
    discovery=sorted({a["source"] for a in appearances if a.get("source_type")=="discovery"})
    social=sorted({a["source"] for a in appearances if a.get("source_type")=="social"})
    families=sorted({source_family(source,catalog) for source in general})
    event["sources"]=general
    event["sport_sources"]=sport
    event["discovery_sources"]=discovery
    event["social_sources"]=social
    event["source_families"]=families
    event["source_count"]=len(families)
    event["outlet_count"]=len(general)
    event["sport_source_count"]=len(sport)
    event["discovery_source_count"]=len(discovery)
    choose_representative_title(event)


def add_appearance(event,row,now):
    appearances=event.setdefault("appearances",[])
    source=row["source"]
    existing=next((a for a in appearances if a.get("source")==source),None)
    if existing is None:
        appearances.append({
            "source":source,"source_family":row["source_family"],"source_type":row["source_type"],
            "title":row["title"],"url":row["url"],"canonical_url":row["canonical_url"],
            "published_at":row.get("published_at"),"publication_date_source":row.get("publication_date_source"),
            "first_seen_at":now,"last_seen_at":now
        })
    else:
        existing["last_seen_at"]=now
        existing["title"]=row["title"]
        existing["url"]=row["url"]
        existing["canonical_url"]=row["canonical_url"]
        if row.get("published_at"):
            existing["published_at"]=row["published_at"]
            existing["publication_date_source"]=row.get("publication_date_source")
    event["last_seen_at"]=now
    if not event.get("canonical_url"):
        event["canonical_url"]=row["canonical_url"]


def event_variants(event):
    return [value for value in [event.get("canonical_title","")] +
            [a.get("title","") for a in event.get("appearances",[])] if value]


def events_match(left,right):
    if titles_match(left.get("canonical_title",""),right.get("canonical_title","")):
        return True
    matches=0
    for a in event_variants(left)[-10:]:
        for b in event_variants(right)[-10:]:
            if titles_match(a,b):
                matches+=1
                if matches>=2:
                    return True
    return False


def prune_event_outliers(event):
    appearances=list(event.get("appearances") or [])
    if len(appearances)<3:
        return 0
    graph={i:set() for i in range(len(appearances))}
    for i in range(len(appearances)):
        for j in range(i+1,len(appearances)):
            if titles_match(appearances[i].get("title",""),appearances[j].get("title","")):
                graph[i].add(j);graph[j].add(i)
    seen=set()
    components=[]
    for i in range(len(appearances)):
        if i in seen:
            continue
        stack=[i];comp=set()
        while stack:
            current=stack.pop()
            if current in comp:
                continue
            comp.add(current);seen.add(current);stack.extend(graph[current]-comp)
        components.append(comp)
    components.sort(key=len,reverse=True)
    core=components[0] if components else set()
    if len(core)<2 or len(core)*2<=len(appearances):
        return 0
    kept=[appearances[i] for i in sorted(core)]
    removed=len(appearances)-len(kept)
    event["appearances"]=kept
    return removed


def comparable_url(url):
    try:
        parts=urlsplit(str(url or ""))
        if not parts.hostname or parts.scheme.lower() not in ("http","https") or parts.username or parts.password:
            return ""
        host=parts.hostname.lower()
        if parts.port and not ((parts.scheme.lower()=="https" and parts.port==443) or
                               (parts.scheme.lower()=="http" and parts.port==80)):
            host += ":"+str(parts.port)
        query=[(k,v) for k,v in __import__("urllib.parse",fromlist=["parse_qsl"]).parse_qsl(parts.query,keep_blank_values=True)
               if not k.lower().startswith("utm_") and k.lower() not in {"gclid","fbclid","mc_cid","mc_eid"}]
        return urlunsplit((parts.scheme.lower(),host,parts.path.rstrip("/"),__import__("urllib.parse",fromlist=["urlencode"]).urlencode(sorted(query)),""))
    except (ValueError,TypeError):
        return ""


def event_stage(title):
    value=tokens(title)
    if ({"justicia","fiscalia","juzgado","tribunal"} & value and
            {"envia","remite","remiten","traslada","trasladan","entrega","entregan"} & value):
        return "remitido_justicia"
    return ""


def same_fact(left,right):
    left,right=left or {},right or {}
    urls_a={comparable_url(v) for v in ([left.get("url"),left.get("canonical_url"),left.get("source_url")]+list(left.get("source_urls") or [])+list(left.get("canonical_urls") or []))}
    urls_b={comparable_url(v) for v in ([right.get("url"),right.get("canonical_url"),right.get("source_url")]+list(right.get("source_urls") or [])+list(right.get("canonical_urls") or []))}
    if (urls_a-{""}) & (urls_b-{""}):
        return True
    titles_a=[str(x) for x in ([left.get("title") or left.get("canonical_title")]+list(left.get("aliases") or [])) if x][:12]
    titles_b=[str(x) for x in ([right.get("title") or right.get("canonical_title")]+list(right.get("aliases") or [])) if x][:12]
    for a in titles_a:
        a_tokens=tokens(a)
        if len(a_tokens)<3:
            continue
        for b in titles_b:
            if event_stage(a)!=event_stage(b):
                continue
            b_tokens=tokens(b)
            if len(b_tokens)<3:
                continue
            common=a_tokens&b_tokens
            if len(common)<3:
                continue
            opposite={"rechaza","desestima","archiva","cierra","revoca"}
            opening={"abre","abrir","incoa","iniciar"}
            if ((a_tokens&opposite and b_tokens&opening) or
                    (b_tokens&opposite and a_tokens&opening)):
                continue
            overlap=len(common)/min(len(a_tokens),len(b_tokens))
            jaccard=len(common)/len(a_tokens|b_tokens)
            likeness=SequenceMatcher(None,normalize(a),normalize(b)).ratio()
            concrete={"morir","suspension","ciberataque","denuncia","exigir","dimision","detenido",
                      "policia","disparo","incendio","asalto","sentencia","accidente","rescate",
                      "vincular","robo","investigar","filtracion","reabrir","ejecucion","emision","sancion"}
            anchored=bool(common&concrete)
            if (a_tokens==b_tokens or
                (len(common)>=4 and overlap>=0.69 and jaccard>=0.40) or
                (anchored and len(common)>=5 and overlap>=0.48 and jaccard>=0.28) or
                (len(common)>=3 and overlap>=0.79 and jaccard>=0.52) or
                (len(common)>=3 and likeness>=0.84 and overlap>=0.56)):
                return True
    return False


def is_material_update(title,prior):
    old=set(prior.get("fact_tokens") or tokens(prior.get("canonical_title") or prior.get("title","")))
    new=tokens(title)
    return bool((new-old)&{TOKEN_ALIASES.get(x,x) for x in MATERIAL_TOKENS} | ((new-old)&MATERIAL_TOKENS))
