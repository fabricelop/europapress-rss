#!/usr/bin/env python3
"""End-to-end check of Top 10 + one outstanding Top 11-30 slot."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

source=Path(__file__).resolve().parents[2]/"trends"/"auto_queue_new.py"

def load(path):
    return json.loads(path.read_text(encoding="utf8"))

def put(path,data):
    path.write_text(json.dumps(data,ensure_ascii=False),encoding="utf8")

with tempfile.TemporaryDirectory() as temp:
    folder=Path(temp)
    shutil.copy2(source,folder/"auto_queue_new.py")
    names=[f"Tendencia {i}" for i in range(1,31)]
    put(folder/"recent.json",{
        "selection_method":"consensus","sources_used":["social-A","social-B"],
        "items":[{"name":name,"rank":i} for i,name in enumerate(names,1)],
        "upcoming":[{"name":"Tendencia 31","rank":31}],
    })
    put(folder/"requests.json",{"requests":[]})
    put(folder/"telegram-manual-explained.json",{"items":[]})
    put(folder/"prepared.json",{"items":[]})
    def run():
        p=subprocess.run([sys.executable,str(folder/"auto_queue_new.py")],
                         cwd=folder,capture_output=True,text=True)
        assert p.returncode==0,(p.stdout,p.stderr)
        return load(folder/"requests.json")["requests"]
    def pending_outside(rows):
        return [r for r in rows if int(r.get("rank") or 0)>10
                and r.get("status") in {"preparing","update","problematic"}]
    one=run()
    assert len([r for r in one if int(r.get("rank") or 0)<=10])==10
    assert [(r["rank"],r["name"]) for r in pending_outside(one)]==[(11,"Tendencia 11")]
    two=run()
    assert [(r["rank"],r["name"]) for r in pending_outside(two)]==[(11,"Tendencia 11")]
    assert len(two)==len(one), "Repeated radar captures must not fill 11-30 at once"
    for r in two:
        if r["name"]=="Tendencia 11":
            r.update(status="explained",explained_at="2026-10-11T14:00:00+02:00",
                     explanation="Hecho verificado.")
    put(folder/"requests.json",{"requests":two})
    put(folder/"telegram-manual-explained.json",{"items":[{
        "id":next(r["id"] for r in two if r["name"]=="Tendencia 11"),
        "name":"Tendencia 11","status":"explained",
        "revision":0,"explained_at":"2026-10-11T14:00:00+02:00",
        "explanation":"Hecho verificado."
    }]})
    three=run()
    assert [(r["rank"],r["name"]) for r in pending_outside(three)]==[(12,"Tendencia 12")]
    assert not any(r.get("name")=="Tendencia 31" for r in three)
    print("TT_TOP30_QUEUE_OK: Top 10 + exactly one next un-explained in positions 11-30")
