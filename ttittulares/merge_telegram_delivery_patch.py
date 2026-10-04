#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys

TERMINAL={"published","dismissed"}

def load_file(path):
    p=pathlib.Path(path)
    if not p.exists():
        return {"version":3,"items":[]}
    raw=p.read_text(encoding="utf-8").strip()
    return json.loads(raw) if raw else {"version":3,"items":[]}

def keyed(doc):
    return {str(x.get("delivery_key") or ""):x for x in doc.get("items",[]) if x.get("delivery_key")}

def build(current_path, patch_path):
    current=load_file(current_path)
    try:
        raw=subprocess.check_output(
            ["git","show",f"HEAD:{current_path}"],
            text=True,encoding="utf-8"
        )
        base=json.loads(raw)
    except Exception:
        base={"items":[]}
    b=keyed(base)
    changed=[]
    for row in current.get("items",[]):
        key=str(row.get("delivery_key") or "")
        if not key:
            continue
        if key not in b or b[key] != row:
            changed.append(row)
    pathlib.Path(patch_path).write_text(
        json.dumps({"version":1,"rows":changed},ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )
    print("TTITTULARES_DELIVERY_PATCH_ROWS="+str(len(changed)))

def apply(patch_path, current_path):
    current=load_file(current_path)
    patch=load_file(patch_path)
    items=current.get("items") or []
    by=keyed(current)
    for incoming in patch.get("rows",[]):
        key=str(incoming.get("delivery_key") or "")
        if not key:
            continue
        existing=by.get(key)
        if existing is None:
            row=dict(incoming)
            items.append(row)
            by[key]=row
            continue
        terminal=str(existing.get("status") or "").lower() in TERMINAL
        keep={}
        if terminal:
            for k in ("status","published_at","dismissed_at","decision_source"):
                if k in existing:
                    keep[k]=existing[k]
        existing.update(incoming)
        if terminal:
            existing.update(keep)
    current["version"]=max(3,int(current.get("version") or 1))
    current["items"]=items[-500:]
    current["count"]=len(current["items"])
    current["updated_at"]=patch.get("updated_at") or current.get("updated_at")
    pathlib.Path(current_path).write_text(
        json.dumps(current,ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )

def main():
    if len(sys.argv)!=4 or sys.argv[1] not in {"build","apply"}:
        raise SystemExit("uso: merge_telegram_delivery_patch.py build|apply <src> <dst>")
    mode,a,b=sys.argv[1:]
    if mode=="build":
        build(a,b)
    else:
        apply(a,b)

if __name__=="__main__":
    main()
