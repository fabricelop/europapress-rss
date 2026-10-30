#!/usr/bin/env python3
"""All pending Top 30 entries are automatic; histories and manual work survive."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

source = Path(__file__).resolve().parents[2] / "trends" / "auto_queue_new.py"
reconcile_source = source.with_name("reconcile_prepared_ready.py")

def load(path):
    return json.loads(path.read_text(encoding="utf8"))

def put(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf8")

with tempfile.TemporaryDirectory() as foldername:
    folder = Path(foldername)
    shutil.copy2(source, folder / "auto_queue_new.py")
    shutil.copy2(reconcile_source, folder / "reconcile_prepared_ready.py")
    names = [f"Tendencia {i}" for i in range(1, 31)]
    put(folder / "recent.json", {
        "selection_method": "consensus", "sources_used": ["social-A", "social-B"],
        "items": [{"name": name, "rank": i} for i, name in enumerate(names, 1)],
        "upcoming": [{"name": "Tendencia 31", "rank": 31}],
    })
    put(folder / "requests.json", {"requests": []})
    put(folder / "telegram-manual-explained.json", {"items": []})
    put(folder / "prepared.json", {"items": []})

    def run():
        p = subprocess.run([sys.executable, str(folder / "auto_queue_new.py")],
                           cwd=folder, capture_output=True, text=True)
        assert p.returncode == 0, (p.stdout, p.stderr)
        return load(folder / "requests.json")["requests"]

    first = run()
    auto = [x for x in first if x.get("auto_queued") and x.get("status") == "preparing"]
    assert len(auto) == 30, auto
    assert {x["rank"] for x in auto} == set(range(1, 31)), auto
    assert all(x["auto_queue_scope"] == "top30" for x in auto)
    assert load(folder / "editorial-queue.json")["count"] == 30
    assert len(run()) == len(first), "A second tick must not duplicate Top 30 work"
    assert not any(x["name"] == "Tendencia 31" for x in first)

    # Existing user requests and legacy rank 11 investigations remain active.
    stamp = datetime.now(ZoneInfo("Europe/Madrid")).isoformat(timespec="seconds")
    manual = {"id": "manual-r17", "name": "Tendencia 17", "rank": 17,
              "status": "preparing", "requested_at": stamp,
              "request_source": "github_pages_authorized_issue", "auto_queued": False,
              "revision": 1, "user_pistas": "Conservar estas pistas"}
    legacy = {"id": "legacy-r11", "name": "Tendencia 11", "rank": 11,
              "status": "preparing", "requested_at": stamp, "auto_queued": True,
              "auto_queue_scope": "next_unexplained_11_30", "revision": 0}
    requests = [x for x in first if x["rank"] not in {11, 17}] + [manual, legacy]
    put(folder / "requests.json", {"requests": requests})
    after = run()
    assert next(x for x in after if x["id"] == "manual-r17") == manual
    assert next(x for x in after if x["id"] == "legacy-r11")["status"] == "preparing"
    assert load(folder / "editorial-queue.json")["count"] == 30

    # The same revision of a closed card never reopens just because rank 28
    # is now automatic. A currently explained rank 27 is not researched again.
    fresh = datetime.now(ZoneInfo("Europe/Madrid")).isoformat(timespec="seconds")
    request_rows = [x for x in after if x["rank"] not in {27, 28}]
    request_rows += [
        {"id": "already-ready", "name": "Tendencia 27", "rank": 27,
         "revision": 0, "status": "explained", "explained_at": fresh,
         "explanation": "TT#27 Tendencia 27 es tendencia por un hecho comprobado."},
        {"id": "already-closed", "name": "Tendencia 28", "rank": 28,
         "revision": 0, "status": "preparing", "requested_at": fresh},
    ]
    put(folder / "requests.json", {"requests": request_rows})
    put(folder / "telegram-manual-explained.json", {"items": [request_rows[-2]]})
    put(folder / "mobile-decisions.json", {"items": [{"id": "already-closed",
        "revision": 0, "status": "published", "updated_at": fresh}]})
    after = run()
    assert next(x for x in after if x["id"] == "already-closed")["status"] == "published"
    assert next(x for x in after if x["id"] == "already-ready")["status"] == "explained"
    assert not any(x["id"] in {"already-ready", "already-closed"}
                   for x in load(folder / "editorial-queue.json")["items"])
    before_ids = {x["id"] for x in after}
    # Unreliable stale captures must not auto-select a newly visible rank 30.
    snapshot = load(folder / "recent.json")
    snapshot["selection_method"] = "stale-fallback"
    snapshot["items"][-1] = {"name": "Never queue from stale radar", "rank": 30}
    put(folder / "recent.json", snapshot)
    assert {x["id"] for x in run()} == before_ids
    print("TT_TOP30_AUTOMATIC_OK: 1-30, idempotency, manual work, closures and fresh explanations")

# A name returning in Top 30 days later must be a new editorial event, not
# silently suppressed by a deleted delivery from an unrelated old match.
with tempfile.TemporaryDirectory() as foldername:
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    folder=Path(foldername)
    shutil.copy2(source, folder/"auto_queue_new.py")
    shutil.copy2(reconcile_source, folder/"reconcile_prepared_ready.py")
    old=(datetime.now(ZoneInfo("Europe/Madrid"))-timedelta(days=5)).isoformat(timespec="seconds")
    put(folder/"recent.json",{"selection_method":"consensus","sources_used":["social-A","social-B"],
        "items":[{"name":"Pubill","rank":17},{"name":"Fuera del Top 30","rank":31}]})
    put(folder/"requests.json",{"requests":[{"id":"pubill-old","name":"Pubill","rank":4,
        "revision":1,"status":"deleted","auto_queued":True,
        "explained_at":old,"deleted_at":old,"explanation":"Partido antiguo"}]})
    put(folder/"telegram-manual-explained.json",{"items":[{"id":"pubill-old",
        "name":"Pubill","revision":1,"status":"explained",
        "explained_at":old,"explanation":"Partido antiguo"}]})
    put(folder/"telegram-image-deliveries.json",{"items":[{"event_id":"pubill-old",
        "name":"Pubill","status":"deleted","deleted_at":old}]})
    put(folder/"prepared.json",{"items":[]})
    def update():
        result=subprocess.run([sys.executable,str(folder/"auto_queue_new.py")],
            cwd=folder,capture_output=True,text=True)
        assert result.returncode==0,(result.stdout,result.stderr)
        return load(folder/"requests.json")["requests"]
    first=update()
    assert len(first)==1,first
    assert first[0]["status"]=="deleted" and first[0]["id"]=="pubill-old",first
    assert len(update())==1,"Age alone must not revive a deleted episode"
    assert load(folder/"editorial-queue.json")["count"]==0
    print("TT_TOP30_TERMINAL_HISTORY_RETAINED_OK")


# Explanation age alone never opens a new publication; maintenance verifies new facts.
with tempfile.TemporaryDirectory() as foldername:
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    folder=Path(foldername)
    shutil.copy2(source, folder/"auto_queue_new.py")
    shutil.copy2(reconcile_source, folder/"reconcile_prepared_ready.py")
    now=datetime.now(ZoneInfo("Europe/Madrid"))
    old=(now-timedelta(hours=49)).isoformat(timespec="seconds")
    recent=(now-timedelta(hours=47)).isoformat(timespec="seconds")
    put(folder/"recent.json",{
      "selection_method":"consensus","sources_used":["social-A","social-B"],
      "items":[{"name":"Tendencia antigua","rank":30},{"name":"Tendencia vigente","rank":11}]})
    requests=[
      {"id":"ancient-r0","name":"Tendencia antigua","status":"grouped",
       "revision":0,"rank":1,"explained_at":old,"explanation":"Texto de ayer"},
      {"id":"recent-r0","name":"Tendencia vigente","status":"explained",
       "revision":0,"rank":2,"explained_at":recent,"explanation":"Texto reciente"},
    ]
    put(folder/"requests.json",{"requests":requests})
    put(folder/"telegram-manual-explained.json",{"items":[
      {"id":r["id"],"name":r["name"],"revision":0,"status":"explained",
       "explained_at":r["explained_at"],"explanation":r["explanation"]}
      for r in requests]})
    put(folder/"prepared.json",{"items":[]})
    result=subprocess.run([sys.executable,str(folder/"auto_queue_new.py")],
      cwd=folder,capture_output=True,text=True)
    assert result.returncode==0,(result.stdout,result.stderr)
    current=load(folder/"requests.json")["requests"]
    fresh=[r for r in current if r["name"]=="Tendencia antigua" and r["id"]!="ancient-r0"]
    assert not fresh,current
    assert len([r for r in current if r["name"]=="Tendencia vigente"])==1,current
    assert load(folder/"editorial-queue.json")["count"]==0
    print("TT_TOP30_AGE_REQUIRES_CONDITIONAL_REVIEW_OK")

# Existing narrow-topic closure and stale manual-group regressions still apply.
with tempfile.TemporaryDirectory() as foldername:
    folder = Path(foldername)
    shutil.copy2(source, folder / "auto_queue_new.py")
    shutil.copy2(reconcile_source, folder / "reconcile_prepared_ready.py")
    put(folder / "recent.json", {"selection_method":"consensus",
        "sources_used":["social-A","social-B"],
        "items":[{"name":f"Tendencia {i}","rank":i} for i in range(1,31)]})
    put(folder / "requests.json", {"requests":[]})
    put(folder / "telegram-manual-explained.json", {"items":[]})
    put(folder / "prepared.json", {"items":[]})
    def run():
        result = subprocess.run([sys.executable,str(folder/"auto_queue_new.py")],
            cwd=folder,capture_output=True,text=True)
        assert result.returncode == 0, (result.stdout,result.stderr)
        return load(folder/"requests.json")["requests"]
    run()
    # Regression: a closed Telegram card under an equivalent holiday label
    # must not reopen another automatic editorial package.
    from datetime import datetime
    from zoneinfo import ZoneInfo
    now=datetime.now(ZoneInfo("Europe/Madrid")).isoformat(timespec="seconds")
    snapshot=load(folder / "recent.json")
    snapshot["items"][1]["name"]="Hispanidad"
    snapshot["items"][4]["name"]="#12DeOctubre"
    snapshot["items"][10]["name"]="Feliz 12"
    put(folder / "recent.json", snapshot)
    put(folder / "telegram-image-deliveries.json", {"items": [{
        "event_id":"closed-holiday","name":"Feliz Día de la Hispanidad",
        "status":"deleted","deleted_at":now,"delivered_at":now}]})
    queued=run()
    names={x["name"]:x for x in queued}
    assert "Hispanidad" not in names or names["Hispanidad"]["status"] not in {"preparing","update"}, queued
    assert "#12DeOctubre" not in names or names["#12DeOctubre"]["status"] not in {"preparing","update"}, queued
    # Manual preparation is still allowed, including a related topic.
    queued = [r for r in queued if r.get("name") != "Feliz 12"]
    queued.append({"id":"manual-feliz-12","name":"Feliz 12","rank":11,
                   "auto_queued":False,"request_source":"github_pages_authorized_issue",
                   "revision":1,"status":"preparing","requested_at":now})
    put(folder / "requests.json", {"requests":queued})
    after=run()
    assert any(x["id"]=="manual-feliz-12" and x["status"]=="preparing"
               for x in after), after
    # Manually requested Feliz 12 (08:44) must not be auto-completed by the
    # earlier deleted holiday package explained at 07:47.
    stale_time = "2026-10-12T07:47:45+02:00"
    later_time = "2026-10-12T08:44:37+02:00"
    stale_doc={"id":"old-group", "name":"Feliz Día de la Hispanidad",
               "status":"explained","explained_at":stale_time,
               "explanation":"Old holiday explanation",
               "telegram_package_status":"deleted",
               "grouped_member_revisions":[
                 {"id":"manual-feliz-12","revision":1}]}
    put(folder / "telegram-manual-explained.json", {"items":[stale_doc]})
    for row in after:
        if row.get("id")=="manual-feliz-12":
            row.update(status="explained",requested_at=later_time,
                       explained_at=stale_time,
                       explanation="Old holiday explanation")
    put(folder / "requests.json", {"requests":after})
    fixed=run()
    manual_fixed=next(x for x in fixed if x.get("id")=="manual-feliz-12")
    assert manual_fixed["status"]=="preparing",manual_fixed
    assert not manual_fixed.get("explanation"),manual_fixed
    print("TT_TOP30_CLOSED_TOPIC_AND_MANUAL_GROUP_OK")
