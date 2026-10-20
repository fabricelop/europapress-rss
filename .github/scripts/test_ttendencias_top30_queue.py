#!/usr/bin/env python3
"""Top 30 is display only: 1-10 automatic, 11-30 only manual."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(__file__).resolve().parents[2] / "trends" / "auto_queue_new.py"

def load(path):
    return json.loads(path.read_text(encoding="utf8"))

def put(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf8")

with tempfile.TemporaryDirectory() as foldername:
    folder = Path(foldername)
    shutil.copy2(source, folder / "auto_queue_new.py")
    names = [f"Tendencia {i}" for i in range(1, 31)]
    put(folder / "recent.json", {
        "selection_method": "consensus",
        "sources_used": ["social-A", "social-B"],
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
    auto = [x for x in first if x.get("auto_queued") and
            x.get("status") in {"preparing", "update", "problematic"}]
    assert len(auto) == 10, auto
    assert {x["rank"] for x in auto} == set(range(1, 11)), auto
    assert len(run()) == len(first), "Top 30 cannot auto-fill ranks 11-30"

    manual = {
        "id": "manual-r17", "name": "Tendencia 17", "rank": 17,
        "status": "preparing", "requested_at": "2026-10-11T21:00:00+02:00",
        "request_source": "github_pages_authorized_issue",
        "auto_queued": False, "revision": 1
    }
    put(folder / "requests.json", {"requests": [*first, manual]})
    after_manual = run()
    assert any(x["id"] == "manual-r17" and x["status"] == "preparing"
               for x in after_manual), after_manual
    assert not any(x.get("auto_queued") and int(x.get("rank") or 0) > 10
                   and x.get("status") in {"preparing", "update", "problematic"}
                   for x in after_manual)

    # Regression: old mistakenly auto-queued rank 11 is retired, but the
    # manual rank 17 is preserved and no historical explanation is removed.
    legacy = {
        "id": "legacy-r11", "name": "Tendencia 11", "rank": 11,
        "status": "preparing", "auto_queued": True,
        "auto_queue_scope": "next_unexplained_11_30",
    }
    put(folder / "requests.json", {"requests": [*after_manual, legacy]})
    cleaned = run()
    assert any(x["id"] == "legacy-r11" and x["status"] == "inactive"
               for x in cleaned), cleaned
    assert any(x["id"] == "manual-r17" and x["status"] == "preparing"
               for x in cleaned), cleaned
    assert not any(x["name"] == "Tendencia 31" for x in cleaned)

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
    print("TT_TOP30_MANUAL_ONLY_OK: Top10 auto, Top11-30 manual, stale group ignored")


# A name returning in Top 10 days later must be a new editorial event, not
# silently suppressed by a deleted delivery from an unrelated old match.
with tempfile.TemporaryDirectory() as foldername:
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    folder=Path(foldername)
    shutil.copy2(source, folder/"auto_queue_new.py")
    old=(datetime.now(ZoneInfo("Europe/Madrid"))-timedelta(days=5)).isoformat(timespec="seconds")
    put(folder/"recent.json",{"selection_method":"consensus","sources_used":["social-A","social-B"],
        "items":[{"name":"Pubill","rank":1},{"name":"Solo manual","rank":11}]})
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
    assert len(first)==2,first
    assert first[0]["status"]=="deleted" and first[0]["id"]=="pubill-old",first
    assert first[1]["name"]=="Pubill" and first[1]["status"]=="preparing",first
    assert first[1]["id"]!="pubill-old" and first[1]["revision"]==0,first
    assert "explanation" not in first[1],first
    assert len(update())==2,"No duplicate Top10 reopen on second refresh"
    assert load(folder/"editorial-queue.json")["count"]==1
    # Rank volatility cannot silently remove an already accepted investigation.
    snapshot=load(folder/"recent.json")
    snapshot["items"][0]={"name":"Otra tendencia","rank":1}
    put(folder/"recent.json",snapshot)
    after_rank_change=update()
    assert any(x["id"]==first[1]["id"] and x["status"]=="preparing" for x in after_rank_change)
    pending=load(folder/"editorial-queue.json")["items"]
    assert any(x["id"]==first[1]["id"] and x["name"]=="Pubill" for x in pending),pending
    print("TT_TOP10_REENTRY_OK: old closure retained, new episode and queue continuity")
