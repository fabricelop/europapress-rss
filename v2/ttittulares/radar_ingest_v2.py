#!/usr/bin/env python3
"""Pure radar/ingestion core for TTiTTulares V2. No network, GitHub, ChatGPT or writes."""
from __future__ import annotations
import copy
import hashlib
import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urlsplit

try:
    from .source_catalog_v2 import load_catalog, source_map, source_family
    from .content_filters_v2 import filter_row
    from .source_publication_v2 import clean_feed_value, parse_publication_date, utc_iso
    from .identity_v2 import (normalize, tokens, fingerprint, best_match, titles_match,
        has_independent_evidence_consensus, add_appearance, recalc_event_sources, title_match_value,
        prune_event_outliers, events_match, same_fact, is_material_update, comparable_url)
    from .source_health_v2 import project_source_health
except ImportError:
    from source_catalog_v2 import load_catalog, source_map, source_family
    from content_filters_v2 import filter_row
    from source_publication_v2 import clean_feed_value, parse_publication_date, utc_iso
    from identity_v2 import (normalize, tokens, fingerprint, best_match, titles_match,
        has_independent_evidence_consensus, add_appearance, recalc_event_sources,
        prune_event_outliers, events_match, same_fact, is_material_update, comparable_url)
    from source_health_v2 import project_source_health

ROOT=Path(__file__).resolve().parent
CATALOG=load_catalog()
SOURCE_MAP=source_map(CATALOG)
WAITING_TTL_HOURS=int(CATALOG["policy"]["waiting_ttl_hours"])
MINIMUM_FAMILIES=int(CATALOG["policy"]["minimum_general_families"])


def _aware(value):
    if not isinstance(value,datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    return value.astimezone(timezone.utc)


def _parse_time(value):
    try:
        result=datetime.fromisoformat(str(value).replace("Z","+00:00"))
        if result.tzinfo is None:
            result=result.replace(tzinfo=timezone.utc)
        return result.astimezone(timezone.utc)
    except (TypeError,ValueError,OverflowError):
        return None


def _clean_title(value, source=""):
    text=clean_feed_value(value)
    # V1 Google News aggregations append the publisher name; trim only for the two
    # discovery feeds, not arbitrary publisher headlines containing a dash.
    if source in ("Reuters Radar","AP Radar"):
        text=re.sub(r"\s+-\s+[^-]{2,80}$","",text)
    return text[:500]


def canonical_url(value):
    try:
        parsed=urlsplit(str(value or "").strip())
        if parsed.scheme.lower() not in ("http","https") or not parsed.hostname or parsed.username or parsed.password:
            return ""
        host=parsed.hostname.lower()
        if parsed.port and not ((parsed.scheme.lower()=="https" and parsed.port==443) or
                                (parsed.scheme.lower()=="http" and parsed.port==80)):
            host += ":"+str(parsed.port)
        return parsed.scheme.lower()+"://"+host+parsed.path.rstrip("/")
    except (TypeError,ValueError):
        return ""


def stable_event_id(seed):
    digest=hashlib.sha256(("ttittulares-v2|"+str(seed)).encode("utf-8")).hexdigest()[:24]
    return "ttn2-"+digest


def _normalize_rows(rows,catalog,now):
    accepted=[]
    filtered=[]
    seen=set()
    order={row["name"]:i for i,row in enumerate(catalog["sources"])}
    for raw in rows or []:
        if not isinstance(raw,dict):
            filtered.append({"reason":"invalid_row","stage":"input"})
            continue
        source=str(raw.get("source") or "").strip()
        definition=(catalog.get("_source_map") or source_map(catalog)).get(source)
        if not definition:
            filtered.append({"source":source,"title":str(raw.get("title") or "")[:160],"reason":"unknown_source","stage":"input"})
            continue
        title=_clean_title(raw.get("title") or "",source)
        url=str(raw.get("url") or raw.get("link") or "").strip()
        normalized_url=canonical_url(url)
        if not title or not normalized_url:
            filtered.append({"source":source,"title":title[:160],"reason":"missing_title_or_http_url","stage":"input"})
            continue
        source_type=definition["type"]
        reason=filter_row(title,url,source_type)
        if reason:
            filtered.append({"source":source,"title":title[:160],"url":normalized_url,"reason":reason,"stage":"editorial_filter"})
            continue
        published=None
        publication_source=None
        # Discovery aggregators never supply the publisher's publication time.
        publisher_date_source=str(raw.get("publication_date_source") or "")
        if (source_type=="general" and raw.get("published_at")
                and publisher_date_source in ("publisher_feed","publisher_article_metadata","publisher")):
            parsed=parse_publication_date(raw.get("published_at"),now)
            if parsed:
                published=utc_iso(parsed)
                publication_source=publisher_date_source
        key=(source,normalized_url)
        row={
            "source":source,"source_family":definition["family"],"source_type":source_type,
            "title":title,"url":url,"canonical_url":normalized_url,
            "published_at":published,"publication_date_source":publication_source,
            "_order":order[source]
        }
        # Same source+article repeated by fallbacks is one appearance per scan.
        if key in seen:
            continue
        seen.add(key)
        accepted.append(row)
    accepted.sort(key=lambda x:(x["_order"],normalize(x["title"]),x["canonical_url"]))
    for row in accepted:
        row.pop("_order",None)
    return accepted,filtered


def _new_candidate(row,now):
    seed=row["source_family"]+"|"+row["canonical_url"]+"|"+normalize(row["title"])
    event_id=stable_event_id(seed)
    event={
        "event_id":event_id,"canonical_title":row["title"],"canonical_url":row["canonical_url"],
        "aliases":[],"first_seen_at":now,"last_seen_at":now,
        "status":"monitoring","revision":1,"reason":"initial",
        "appearances":[],"source_count":0,"outlet_count":0,"source_families":[],
        "sport_source_count":0,"discovery_source_count":0,"editorial_job_id":None,
        "eligible_at":None,"expired_at":None
    }
    return event


class _TokenLookup:
    """Conservative inverted lookup: NEVER discards a possible semantic match.

    Every non-URL title match needs at least two common fingerprint tokens;
    `same_fact` needs at least three. Index unioned title variants and verify
    the original identity predicates on the reduced, insertion-ordered set.
    """

    def __init__(self, rows=()):
        self.positions = {}
        self.rows = {}
        self.by_token = defaultdict(set)
        self.by_url = defaultdict(set)
        for row in rows:
            self.add(row)

    def add(self, row, *, variants=None, urls=()):
        key = row["event_id"]
        if key not in self.positions:
            self.positions[key] = len(self.positions)
        self.rows[key] = row
        if variants is None:
            variants = [row.get("canonical_title", "")] + [
                x.get("title", "") for x in row.get("appearances", [])]
        for title in variants:
            for token in tokens(title):
                self.by_token[token].add(key)
        for url in urls:
            if url:
                self.by_url[url].add(key)

    def candidates(self, title, *, min_common=2, url=""):
        counts = Counter(key for token in tokens(title) for key in self.by_token.get(token, ()))
        ids = {key for key, count in counts.items() if count >= min_common}
        if url:
            ids.update(self.by_url.get(url, ()))
        return [self.rows[key] for key in sorted(ids, key=self.positions.__getitem__)]


def _merge_candidate_events(events,catalog,protected_ids=None):
    protected_ids=set(protected_ids or ())
    ordered=sorted(events.values(),key=lambda x:(x.get("first_seen_at",""),x["event_id"]))
    kept=[]
    remap={}
    lookup=_TokenLookup()
    for event in ordered:
        if event.get("status") not in ("monitoring","eligible"):
            kept.append(event)
            continue
        target=None
        matching=set()
        for title in [event.get("canonical_title", "")] + [
                a.get("title", "") for a in event.get("appearances", [])]:
            matching.update(x["event_id"] for x in lookup.candidates(title))
        for prior in sorted((lookup.rows[key] for key in matching),
                            key=lambda x: lookup.positions[x["event_id"]]):
            if prior.get("status") not in ("monitoring","eligible"):
                continue
            # Never rewrite an event_id that already exists in the persisted news index.
            if event["event_id"] in protected_ids or prior["event_id"] in protected_ids:
                continue
            if events_match(event,prior):
                target=prior
                break
        if target is None:
            kept.append(event)
            if event["event_id"] not in protected_ids:
                lookup.add(event)
            continue
        by_source={a.get("source"):dict(a) for a in target.get("appearances",[]) if a.get("source")}
        for appearance in event.get("appearances",[]):
            source=appearance.get("source")
            if not source:
                continue
            old=by_source.get(source)
            if old is None:
                by_source[source]=dict(appearance)
            else:
                first=min(str(old.get("first_seen_at") or ""),str(appearance.get("first_seen_at") or ""))
                last=max(str(old.get("last_seen_at") or ""),str(appearance.get("last_seen_at") or ""))
                if last==str(appearance.get("last_seen_at") or ""):
                    old.update(appearance)
                old["first_seen_at"]=first
                old["last_seen_at"]=last
        target["appearances"]=list(by_source.values())
        recalc_event_sources(target,catalog)
        if event.get("status")=="eligible":
            target["status"]="eligible"
            target["eligible_at"]=target.get("eligible_at") or event.get("eligible_at")
            target["editorial_job_id"]=event.get("editorial_job_id") or target.get("editorial_job_id")
        if len(event.get("canonical_title",""))>len(target.get("canonical_title","")):
            target["canonical_title"]=event["canonical_title"]
        lookup.add(target)
        remap[event["event_id"]]=target["event_id"]
    return {x["event_id"]:x for x in kept},remap


def _index_item_from_candidate(event):
    return {
        "event_id":event["event_id"],
        "canonical_title":event["canonical_title"],
        "aliases":list(event.get("aliases") or []),
        "canonical_urls":[event["canonical_url"]] if event.get("canonical_url") else [],
        "source_families":list(event.get("source_families") or []),
        "fact_tokens":sorted(tokens(event["canonical_title"])),
        "current_revision":int(event.get("revision",1)),
        "status":event.get("status","monitoring"),
        "terminal_status":None,
        "editorial_created":event.get("status")=="eligible",
        "revision_refs":([{
            "revision":int(event.get("revision",1)),"reason":event.get("reason","initial"),
            "status":"pending","requested_at":event.get("eligible_at"),
            "editorial_job_id":event.get("editorial_job_id")
        }] if event.get("status")=="eligible" else []),
        "first_seen_at":event["first_seen_at"],
        "last_seen_at":event["last_seen_at"]
    }


def _update_index_from_event(index,event):
    item=index.setdefault(event["event_id"],_index_item_from_candidate(event))
    item["canonical_title"]=event["canonical_title"]
    item["aliases"]=list(dict.fromkeys(list(item.get("aliases") or [])+[a.get("title","") for a in event.get("appearances",[]) if a.get("title")]))[:20]
    urls=list(item.get("canonical_urls") or [])
    urls.extend(a.get("canonical_url") for a in event.get("appearances",[]) if a.get("canonical_url"))
    item["canonical_urls"]=list(dict.fromkeys(x for x in urls if x))[-40:]
    item["source_families"]=sorted(set(item.get("source_families") or [])|set(event.get("source_families") or []))
    item["fact_tokens"]=sorted(set(item.get("fact_tokens") or [])|set(tokens(event["canonical_title"])))
    item["last_seen_at"]=event.get("last_seen_at")
    if event.get("status") in ("monitoring","archived","eligible"):
        item["status"]=event.get("status")
    if event.get("status")=="eligible":
        item["status"]="eligible"
        item["editorial_created"]=True
        item["current_revision"]=int(event.get("revision",1))
        refs=list(item.get("revision_refs") or [])
        if not any(int(x.get("revision",0))==int(event.get("revision",1)) for x in refs):
            refs.append({"revision":int(event.get("revision",1)),"reason":event.get("reason","initial"),
                         "status":"pending","requested_at":event.get("eligible_at"),
                         "editorial_job_id":event.get("editorial_job_id")})
        item["revision_refs"]=refs
    return item


def _index_match(row,index_items,lookup=None):
    candidates=[]
    possible=(lookup.candidates(row["title"],min_common=3,
                                url=comparable_url(row["canonical_url"]))
              if lookup is not None else index_items.values())
    for item in possible:
        if same_fact(row,item):
            candidates.append(item)
    if not candidates:
        return None
    # Exact canonical URL takes precedence; then the closest known title.
    exact=[]
    for item in candidates:
        urls={canonical_url(x) for x in item.get("canonical_urls",[]) if x}
        urls.add(canonical_url(item.get("canonical_url") or item.get("url") or ""))
        if row["canonical_url"] in urls:
            exact.append(item)
    pool=exact or candidates
    return max(pool,key=lambda x: title_match_value_score(row["title"],x.get("canonical_title","")))


def title_match_value_score(a,b):
    return title_match_value(a,b)


def _append_appearance(event,row,now,catalog):
    add_appearance(event,row,now)
    recalc_event_sources(event,catalog)


def _source_appeared_before(row,index_item):
    return row["source_family"] in set(index_item.get("source_families") or [])


def _make_update_candidate(event_id,index_item,row,now):
    return {
        "event_id":event_id,"base_revision":int(index_item.get("current_revision") or 1),
        "first_seen_at":now,"last_seen_at":now,"status":"monitoring",
        "canonical_title":row["title"],"canonical_url":row["canonical_url"],
        "appearances":[],"source_count":0,"source_families":[],
        "reason":"material_update","eligible_at":None
    }


def _material_candidate_add(candidate,row,now,catalog):
    # Do not count an already-known source family as independent update evidence.
    if row["source_family"] in set(candidate.get("base_source_families") or []):
        return False
    add_appearance(candidate,row,now)
    recalc_event_sources(candidate,catalog)
    return True


def ingest_scan(rows, source_statuses, previous_state=None, news_index=None, *, now=None, catalog=None):
    """Pure scan transition. Returns snapshots; never writes files or calls external services."""
    clock=_aware(now or datetime.now(timezone.utc))
    stamp=utc_iso(clock)
    cat=catalog or CATALOG
    # Internal lookup cache is attached to a local copy and never serialized.
    cat_map={row["name"]:row for row in cat["sources"]}
    cat=dict(cat)
    cat["source_map"]=cat_map
    accepted,filtered=_normalize_rows(rows,cat,clock)
    prior=copy.deepcopy(previous_state or {})
    index_doc=copy.deepcopy(news_index or {"schema_version":1,"project":"ttittulares-v2","items":{}})
    if index_doc.get("project") not in (None,"ttittulares-v2"):
        raise ValueError("NEWS_INDEX_PROJECT_MISMATCH")
    index=dict(index_doc.get("items") or {})
    # Live radar keeps its own compact identity ledger for events whose full
    # archived evidence has moved to immutable cold-storage batches. The
    # editorial index can be stale; it is not the archive's source of truth.
    archived_identity=copy.deepcopy(prior.get("archive_index") or {})
    if not isinstance(archived_identity,dict):
        raise ValueError("RADAR_ARCHIVE_INDEX_INVALID")
    for event_id,identity in archived_identity.items():
        if identity.get("event_id")!=event_id or identity.get("status")!="archived":
            raise ValueError("RADAR_ARCHIVE_IDENTITY_INVALID")
        index.setdefault(event_id,identity)
    old_events=prior.get("items") or {}
    if isinstance(old_events,list):
        old_events={x["event_id"]:x for x in old_events if x.get("event_id")}
    events=copy.deepcopy(old_events)
    if set(events)&set(archived_identity):
        raise ValueError("RADAR_ARCHIVE_DUPLICATE_ID")
    protected_event_ids=set(events)|set(archived_identity)
    updates=copy.deepcopy(prior.get("material_updates") or {})
    health=project_source_health(source_statuses,prior.get("source_health") or {},stamp,cat)
    new_events=[]
    material_waiting=[]
    material_eligible=[]

    # Expire uncorroborated items from their FIRST observation, never last_seen.
    cutoff=clock-timedelta(hours=WAITING_TTL_HOURS)
    for event in events.values():
        if event.get("status")!="monitoring":
            continue
        first=_parse_time(event.get("first_seen_at"))
        if first and first<=cutoff:
            event["status"]="archived"
            event["expired_at"]=stamp
            if event["event_id"] in index:
                index[event["event_id"]]["status"]="archived"

    # Each comparison still uses the original identity rules. The inverted
    # indices only avoid impossible all-pairs comparisons in ~2,500 candidates
    # and the growing historical news index. The shorter GitHub CAS window is
    # essential when live editorial consumers update the same branch.
    event_lookup=_TokenLookup()
    for event in events.values():
        if event.get("status") in ("monitoring","eligible"):
            event_lookup.add(event,urls=[event.get("canonical_url","")] + [
                a.get("canonical_url","") for a in event.get("appearances",[])])
    index_lookup=_TokenLookup()
    for item in index.values():
        if not item.get("event_id"):
            continue
        index_lookup.add(item,variants=[item.get("canonical_title","")] +
                         list(item.get("aliases") or [])[:11],
                         urls=[comparable_url(url) for url in
                               ([item.get("url"),item.get("canonical_url"),item.get("source_url")]
                                + list(item.get("source_urls") or [])
                                + list(item.get("canonical_urls") or []))])

    for row in accepted:
        # URL identity is stronger than headline similarity within one source item.
        match=next((e for e in event_lookup.candidates(row["title"],
                                                     url=row["canonical_url"])
                    if e.get("status") in ("monitoring","eligible") and
                    (row["canonical_url"]==e.get("canonical_url") or any(
                        a.get("canonical_url")==row["canonical_url"] for a in e.get("appearances",[])))),None)
        if match is None:
            match,match_score=best_match(row["title"],[e for e in
                 event_lookup.candidates(row["title"])
                 if e.get("status") in ("monitoring","eligible")],0.50)
        if match is not None:
            _append_appearance(match,row,stamp,cat)
            event_lookup.add(match,urls=[row["canonical_url"]])
            # Extra outlets do not create another event or a revision.
            continue

        prior_item=_index_match(row,index,index_lookup)
        if prior_item is not None:
            status=str(prior_item.get("terminal_status") or prior_item.get("status") or "").lower()
            if status in {"published","dismissed","deleted","treated"}:
                continue
            # Only a READY, non-terminal record may open an automatic material-update candidate.
            if (status!="ready" or prior_item.get("terminal_status") or
                    _source_appeared_before(row,prior_item) or
                    not is_material_update(row["title"],prior_item)):
                continue
            event_id=prior_item["event_id"]
            candidate=updates.get(event_id)
            if candidate is None:
                candidate=_make_update_candidate(event_id,prior_item,row,stamp)
                candidate["base_source_families"]=list(prior_item.get("source_families") or [])
                updates[event_id]=candidate
            if (candidate.get("base_revision")!=int(prior_item.get("current_revision") or 1)
                    or candidate.get("status")!="monitoring"):
                continue
            if not any(a.get("source_family")==row["source_family"] for a in candidate.get("appearances",[])):
                _material_candidate_add(candidate,row,stamp,cat)
            continue

        # A candidate that expired at 24h remains in news-index and cannot be silently restarted.
        candidate=_new_candidate(row,stamp)
        # Avoid deterministic ID collisions if a prior identity key already exists.
        if candidate["event_id"] in events or candidate["event_id"] in index:
            candidate["event_id"]=stable_event_id(row["source_family"]+"|"+row["canonical_url"]+"|"+normalize(row["title"])+"|"+stamp)
        _append_appearance(candidate,row,stamp,cat)
        events[candidate["event_id"]]=candidate
        event_lookup.add(candidate,urls=[row["canonical_url"]])

    # Consolidate candidates split by paraphrased source titles before quorum.
    events,remap=_merge_candidate_events(events,cat,protected_event_ids)
    for event in events.values():
        if event.get("status")=="monitoring":
            prune_event_outliers(event)
            recalc_event_sources(event,cat)
            if (event["source_count"]>=MINIMUM_FAMILIES and
                    has_independent_evidence_consensus(event["appearances"],cat,MINIMUM_FAMILIES)):
                event["status"]="eligible"
                event["eligible_at"]=stamp
                event["reason"]="initial"
                event["editorial_job_id"]=event["event_id"]+"-r1-editorial"
                new_events.append(event)
            else:
                first=_parse_time(event.get("first_seen_at"))
                if first and first<=cutoff:
                    event["status"]="archived"
                    event["expired_at"]=stamp
        if event["event_id"] in index:
            _update_index_from_event(index,event)
        else:
            index[event["event_id"]]=_index_item_from_candidate(event)

    # Material updates are separate candidates: four NEW, independent general families are required.
    for event_id,candidate in list(updates.items()):
        if candidate.get("status")!="monitoring":
            continue
        first=_parse_time(candidate.get("first_seen_at"))
        if first and first<cutoff:
            candidate["status"]="archived"
            candidate["expired_at"]=stamp
            continue
        prune_event_outliers(candidate)
        recalc_event_sources(candidate,cat)
        if (candidate["source_count"]>=MINIMUM_FAMILIES and
                has_independent_evidence_consensus(candidate["appearances"],cat,MINIMUM_FAMILIES)):
            prior_item=index.get(event_id)
            if not prior_item or int(prior_item.get("current_revision") or 1)!=int(candidate["base_revision"]):
                candidate["status"]="problematic"
                candidate["problem_reason"]="base_revision_changed"
                continue
            new_revision=int(candidate["base_revision"])+1
            candidate["status"]="eligible"
            candidate["revision"]=new_revision
            candidate["eligible_at"]=stamp
            candidate["editorial_job_id"]=event_id+"-r"+str(new_revision)+"-editorial"
            candidate["reason"]="material_update"
            candidate["previous_title"]=prior_item.get("canonical_title")
            prior_item["current_revision"]=new_revision
            prior_item["canonical_title"]=candidate["canonical_title"]
            prior_item["status"]="eligible"
            prior_item["source_families"]=sorted(set(prior_item.get("source_families") or [])|
                                                 set(candidate.get("source_families") or []))
            prior_item["fact_tokens"]=sorted(set(prior_item.get("fact_tokens") or [])|
                                              set(tokens(candidate["canonical_title"])))
            prior_item["aliases"]=list(dict.fromkeys(list(prior_item.get("aliases") or [])+
                                                   [candidate["previous_title"]]))[:20]
            refs=list(prior_item.get("revision_refs") or [])
            refs.append({"revision":new_revision,"reason":"material_update","status":"pending",
                         "requested_at":stamp,"editorial_job_id":candidate["editorial_job_id"],
                         "previous_title":candidate["previous_title"]})
            prior_item["revision_refs"]=refs
            prior_item["last_seen_at"]=stamp
            material_eligible.append(candidate)
        else:
            material_waiting.append(candidate)

    # Stable sort for projections; a change in source order or JSON object order cannot reshuffle queue.
    events={key:events[key] for key in sorted(events)}
    updates={key:updates[key] for key in sorted(updates)}
    index={key:index[key] for key in sorted(index)}
    scan_seed=stamp+"|"+"|".join(sorted(row["canonical_url"] for row in accepted))
    scan_id="scan-"+hashlib.sha256(scan_seed.encode("utf-8")).hexdigest()[:16]
    radar_state={
        "schema_version":1,"project":"ttittulares-v2","step":"news_radar_scan",
        "scan_id":scan_id,"observed_at":stamp,"source_catalog_version":cat.get("source_catalog_version"),
        "source_health":health,"items":events,"material_updates":updates,
        "metrics":{
            "input_rows":len(rows or []),"accepted_rows":len(accepted),"filtered_rows":len(filtered),
            "candidate_count":len(events)+len(archived_identity),"monitoring_count":sum(x.get("status")=="monitoring" for x in events.values()),
            "eligible_count":sum(x.get("status")=="eligible" for x in events.values()),
            "archived_count":sum(x.get("status")=="archived" for x in events.values())+len(archived_identity),
            "material_update_waiting":sum(x.get("status")=="monitoring" for x in updates.values()),
            "material_update_eligible":len(material_eligible)
        },
        "effects_enabled":False
    }
    if archived_identity:
        radar_state["archive_index"]=archived_identity
    if prior.get("archive_manifest"):
        radar_state["archive_manifest"]=copy.deepcopy(prior["archive_manifest"])
    index_doc={"schema_version":1,"project":"ttittulares-v2","updated_at":stamp,"items":index}
    return {
        "radar_state":radar_state,"news_index":index_doc,
        "newly_eligible":[copy.deepcopy(x) for x in new_events],
        "material_updates_eligible":[copy.deepcopy(x) for x in material_eligible],
        "filtered":filtered,"accepted_rows":accepted,
        "effects_enabled":False
    }


def main():
    import argparse
    parser=argparse.ArgumentParser(description="Pure preview of an isolated TTiTTulares V2 radar snapshot")
    parser.add_argument("--catalog",default=str(ROOT/"source_catalog_v2.json"))
    parser.add_argument("--input",required=True,help="JSON with rows, source_statuses and optional previous/index state")
    parser.add_argument("--output",help="Optional local output path; must stay under v2/ttittulares/state/")
    args=parser.parse_args()
    payload=json.loads(Path(args.input).read_text(encoding="utf-8"))
    if not isinstance(payload,dict):
        raise ValueError("INPUT_MUST_BE_OBJECT")
    catalog=json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    result=ingest_scan(payload.get("rows"),payload.get("source_statuses"),
                       payload.get("previous_state"),payload.get("news_index"),
                       now=_parse_time(payload.get("now")) if payload.get("now") else datetime.now(timezone.utc),
                       catalog=catalog)
    summary={k:result["radar_state"][k] for k in ("scan_id","observed_at","metrics","effects_enabled")}
    summary["newly_eligible"]=[{"event_id":x["event_id"],"title":x["canonical_title"],"revision":x["revision"]} for x in result["newly_eligible"]]
    summary["material_updates_eligible"]=[{"event_id":x["event_id"],"title":x["canonical_title"],"revision":x["revision"]} for x in result["material_updates_eligible"]]
    summary["publication_enabled"]=False
    encoded=json.dumps(result["radar_state"],ensure_ascii=False,indent=2)+"\n"
    if args.output:
        output=Path(args.output).resolve()
        allowed=(ROOT/"state").resolve()
        if allowed not in output.parents:
            raise ValueError("OUTPUT_MUST_REMAIN_UNDER_V2_TTITTULARES_STATE")
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(encoded,encoding="utf-8")
    print(json.dumps(summary,ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
