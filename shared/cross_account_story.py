"""Cita cruzada TTiTTulares <-> TTendencias.

Modulo sin efectos laterales: detecta una misma historia ya PUBLICADA por la otra
cuenta y prepara el copy autosuficiente y la busqueda de X. No publica, no
escribe estado y no llama a APIs.
"""
from __future__ import annotations

import re
import sys
import unicodedata
import urllib.parse
from datetime import datetime, timezone, timedelta
from difflib import SequenceMatcher

STOPWORDS={
    "de","la","el","los","las","un","una","unos","unas","y","o","e","en","a","al",
    "del","por","para","con","sin","sobre","que","se","es","son","ha","han","su","sus",
    "este","esta","estos","estas","como","mas","tras","entre","desde","hasta","ya","le",
    "les","lo","si","no","fue","ser","muy","pero","porque","durante","frente","cada",
    "todo","toda","todos","todas","tendencia","tendencias"
}

def _norm(text):
    text=unicodedata.normalize("NFKD",str(text or "").lower())
    text="".join(ch for ch in text if not unicodedata.combining(ch))
    text=re.sub(r"https?://\S+"," ",text)
    text=re.sub(r"[^a-z0-9ñ]+"," ",text)
    return " ".join(text.split())

def _tokens(text):
    return [x for x in _norm(text).split() if x not in STOPWORDS and len(x)>2]

def story_score(left_text,right_text,subject=""):
    left=set(_tokens(left_text)); right=set(_tokens(right_text))
    union=left|right; shared=left&right
    jaccard=len(shared)/len(union) if union else 0.0
    containment=len(shared)/min(len(left),len(right)) if left and right else 0.0
    sequence=SequenceMatcher(None,_norm(left_text),_norm(right_text)).ratio()
    anchors=tuple(sorted(x for x in shared if len(x)>=6 or x.isdigit()))
    st=set(_tokens(subject))
    subject_match=False
    if st:
        needed=max(1,len(st)-1)
        subject_match=len(st&left)>=needed and len(st&right)>=needed
    score=(
        .45*containment + .25*jaccard + .15*min(len(anchors)/4.0,1.0)
        + .15*sequence + (.12 if subject_match else 0.0)
    )
    return min(score,1.0),anchors,subject_match

def same_story(left_text,right_text,subject="",threshold=.55):
    score,anchors,subject_match=story_score(left_text,right_text,subject)
    return score>=threshold,score,anchors,subject_match

def _parse_dt(value):
    try:
        return datetime.fromisoformat(str(value or "").replace("Z","+00:00")).astimezone(timezone.utc)
    except Exception:
        return None

def _recent(value,hours=48,now=None):
    dt=_parse_dt(value)
    if not dt:
        return False
    now=now or datetime.now(timezone.utc)
    return dt>=now-timedelta(hours=hours)

def find_published_trend_match(news_text,copy_state,hours=48,threshold=.55,now=None):
    best=None
    for row in (copy_state or {}).get("items",[]):
        if str(row.get("telegram_package_status") or "").lower()!="published":
            continue
        at=row.get("published_at") or row.get("copied_at")
        if not _recent(at,hours,now):
            continue
        explanation=str(row.get("explanation") or "").strip()
        if not explanation:
            continue
        names=[str(x or "").strip() for x in (row.get("trend_names") or []) if str(x or "").strip()]
        subject=names[0] if names else str(row.get("group_title") or row.get("name") or "").strip()
        ok,score,anchors,_=same_story(news_text,explanation,subject,threshold)
        if not ok:
            continue
        cand={
            "score":round(score,6),"subject":subject,"text":explanation,
            "published_at":str(at or ""),"id":str(row.get("item_id") or row.get("id") or ""),
            "revision":int(row.get("revision") or 0),"anchors":list(anchors)
        }
        if best is None or cand["score"]>best["score"]:
            best=cand
    return best

def find_published_news_match(trend_text,subject,deliveries,hours=48,threshold=.55,now=None):
    best=None
    for row in (deliveries or {}).get("items",[]):
        if str(row.get("status") or "").lower()!="published":
            continue
        at=row.get("published_at")
        if not _recent(at,hours,now):
            continue
        source=str(row.get("tweet_text") or row.get("title") or "").strip()
        if not source:
            continue
        ok,score,anchors,_=same_story(source,trend_text,subject,threshold)
        if not ok:
            continue
        cand={
            "score":round(score,6),"title":str(row.get("title") or ""),
            "text":source,"published_at":str(at or ""),
            "id":str(row.get("event_id") or ""),"revision":int(row.get("revision") or 0),
            "anchors":list(anchors)
        }
        if best is None or cand["score"]>best["score"]:
            best=cand
    return best

def without_closer(text):
    lines=[]
    for line in str(text or "").splitlines():
        if line.strip().startswith("🌶️"):
            continue
        lines.append(line)
    return " ".join(" ".join(lines).split()).strip()

def build_ttittulares_quote_copy(normal_tweet,trend_name):
    body=without_closer(normal_tweet)
    subject=str(trend_name or "").strip()
    prefixes=[]
    if subject:
        prefixes.append(f"En @ttendenciasesp te contamos por qué {subject} está en conversación. La noticia: ")
        prefixes.append(f"En @ttendenciasesp, el contexto de {subject}. La noticia: ")
    prefixes += ["En @ttendenciasesp, el contexto. ", "Desde @ttendenciasesp: "]
    for prefix in prefixes:
        candidate=(prefix+body).strip()
        if len(candidate)<=280:
            return candidate
    return None

def build_ttendencias_quote_copy(normal_explanation):
    body=without_closer(normal_explanation)
    body=re.sub(r"^TT#\d+\s+","",body).strip()
    for prefix in ("Lo contamos en @ttittulares: ","En @ttittulares: "):
        candidate=(prefix+body).strip()
        if len(candidate)<=280:
            return candidate
    return None

def search_keywords(*texts,limit=4):
    out=[]; seen=set()
    for text in texts:
        for token in re.findall(r"[^\W_]+",str(text or ""),flags=re.UNICODE):
            key=_norm(token)
            if len(key)<3 or key in STOPWORDS or key.isdigit() or key in seen:
                continue
            seen.add(key); out.append(token)
            if len(out)>=limit:
                return out
    return out

def x_account_search_url(handle,*texts):
    clean=str(handle or "").strip().lstrip("@")
    terms=search_keywords(*texts)
    query=" ".join([f"from:{clean}",*terms]).strip()
    return "https://x.com/search?"+urllib.parse.urlencode({
        "q":query,"src":"typed_query","f":"live"
    })

def _selftest():
    n="CCOO y UGT convocan una huelga general de 24 horas el 11 de noviembre por la crisis de la vivienda. Reclaman salarios suficientes y alquileres e hipotecas asumibles.\n\n🌶️ El mercado inmobiliario ya tiene su propio día de cierre."
    t="TT#10 CCOO es tendencia porque CCOO y UGT convocan para el 11 de noviembre una huelga general por la crisis de la vivienda, la primera conjunta desde 2012 y a 18 días de las elecciones del 29-N.\n🌶️ El calendario sindical ya tiene día de paro."
    ok,score,_,_=same_story(n,t,"CCOO")
    assert ok and score>=.55, score
    a=build_ttittulares_quote_copy(n,"CCOO")
    b=build_ttendencias_quote_copy(t)
    assert a and len(a)<=280 and "@ttendenciasesp" in a
    assert b and len(b)<=280 and "@ttittulares" in b
    u=x_account_search_url("ttendenciasesp",n,t)
    assert "from%3Attendenciasesp" in u
    print("CROSS_ACCOUNT_SELFTEST_OK",round(score,3),len(a),len(b))

if __name__=="__main__":
    if len(sys.argv)>1 and sys.argv[1]=="selftest":
        _selftest()
    else:
        raise SystemExit("uso: cross_account_story.py selftest")
