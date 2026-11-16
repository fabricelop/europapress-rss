#!/usr/bin/env python3
"""Pure source-health projection for TTiTTulares V2."""
from __future__ import annotations


def project_source_health(statuses, previous, now, catalog):
    status_by_name={str(x.get("source") or ""):dict(x) for x in (statuses or []) if x.get("source")}
    old=(previous or {}).get("by_source") or {}
    by_source={}
    rows=[]
    general_healthy=[]
    general_families=set()
    for source in catalog["sources"]:
        name=source["name"]
        incoming=status_by_name.get(name)
        prior=old.get(name) or {}
        if incoming is None:
            ok=False
            state="not_checked"
            items=0
            error=None
            url=None
            latency=None
            fetched_at=None
        else:
            ok=incoming.get("ok") is True
            state="ok" if ok else ("degraded" if incoming.get("degraded") else "failed")
            items=max(0,int(incoming.get("items") or 0))
            error=str(incoming.get("error") or "")[:240] or None
            url=incoming.get("url")
            latency=incoming.get("latency_ms")
            fetched_at=incoming.get("fetched_at") or now
        last_success=fetched_at if ok else prior.get("last_success_at")
        failure_streak=0 if ok else int(prior.get("failure_streak") or 0)+(1 if incoming else 0)
        record={
            "source":name,"type":source["type"],"family":source["family"],
            "state":state,"ok":ok,"items":items,"url":url,"error":error,
            "latency_ms":latency,"checked_at":fetched_at,
            "last_success_at":last_success,"failure_streak":failure_streak
        }
        rows.append(record)
        by_source[name]={"last_success_at":last_success,"failure_streak":failure_streak}
        if source["type"]=="general" and ok:
            general_healthy.append(name)
            general_families.add(source["family"])
    minimum=int(catalog["policy"]["minimum_healthy_general_sources"])
    return {
        "schema_version":1,"updated_at":now,"by_source":by_source,"sources":rows,
        "configured_general_sources":catalog["policy"]["general_sources"],
        "healthy_general_sources":len(general_healthy),
        "healthy_general_families":len(general_families),
        "healthy_general_source_names":sorted(general_healthy),
        "minimum_healthy_general_sources":minimum,
        "health_degraded":len(general_healthy)<minimum
    }
