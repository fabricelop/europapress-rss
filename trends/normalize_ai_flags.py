#!/usr/bin/env python3
import json
from pathlib import Path

PATH = Path("trends/telegram-manual-explained.json")

def main():
    doc=json.loads(PATH.read_text(encoding="utf-8"))
    changed=False
    for row in doc.get("items",[]):
        if str(row.get("status") or "").lower()!="explained" or row.get("tremending_origin"):
            continue
        for key in ("disable_ai_image","ai_image_block_reason","image_block_reason"):
            if key in row:
                row.pop(key,None)
                changed=True
        if str(row.get("ai_image_status") or "").lower()=="disabled":
            row["ai_image_status"]="none"
            changed=True
        for key in ("image_strategy","image_mode"):
            if str(row.get(key) or "").lower() in {"fallback_only","archive_only"}:
                row[key]="ai_plus_fallback"
                changed=True
        if row.get("with_image") is False:
            row["with_image"]=True
            changed=True
    if changed:
        PATH.write_text(json.dumps(doc,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        print("TTENDENCIAS_AI_EDITORIAL_BLOCKS_CLEARED")
    else:
        print("TTENDENCIAS_AI_EDITORIAL_BLOCKS_ALREADY_CLEAR")

if __name__=="__main__":
    main()
