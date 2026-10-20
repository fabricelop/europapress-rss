#!/usr/bin/env python3
"""Request the SAME Windows/ChatGPT TTendencias editorial runner as /run.

Invoked only *after* a manual Telegram Prepare/Rework command has been
persisted to main. GitHub Actions cannot itself write the research; the PC
listener consumes the control branch trigger and runs its editorial prompt.
"""
import base64
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "fabricelop/europapress-rss"
BRANCH = "control/ttendencias-run-trigger"
TARGET = "trends/run-now-trigger.json"
MARKER = "TTendencias: petición de explicación registrada:"
MARKER_REWORK = "vuelve a En elaboración (r"

def is_rework_message(value):
    value = str(value or "")
    return value.startswith("TTendencias: ") and MARKER_REWORK in value

def is_new_request(queue_path="/tmp/tt-mobile-queue-results.json",
                   direct_path="/tmp/tt-mobile-issue-result.txt"):
    try:
        entries=json.loads(Path(queue_path).read_text(encoding="utf8"))
        if isinstance(entries,list) and any(
                x.get("ok") is True and (str(x.get("message") or "").startswith(MARKER)
                                         or is_rework_message(x.get("message")))
                for x in entries if isinstance(x,dict)):
            return True
    except (OSError, ValueError, TypeError):
        pass
    try:
        result=Path(direct_path).read_text(encoding="utf8")
        return result.startswith(MARKER) or is_rework_message(result)
    except OSError:
        return False

def api(url,token,document=None,method="GET"):
    headers={"Authorization":"Bearer "+token,
             "Accept":"application/vnd.github+json",
             "Content-Type":"application/json",
             "User-Agent":"TTendencias-GitHub-Manual-Prepare"}
    request=urllib.request.Request(
        url, headers=headers, method=method,
        data=json.dumps(document,ensure_ascii=False).encode("utf8")
        if document is not None else None)
    with urllib.request.urlopen(request,timeout=25) as response:
        return json.load(response) if response.status != 204 else {}

def trigger(token):
    endpoint=("https://api.github.com/repos/"+REPO+"/contents/"+TARGET+
              "?ref="+urllib.parse.quote(BRANCH,safe=""))
    for attempt in range(5):
        previous=api(endpoint,token)
        old=json.loads(base64.b64decode(previous["content"]))
        current=dt.datetime.now(dt.timezone.utc)
        try:
            age=(current-dt.datetime.fromisoformat(
                str(old.get("requested_at") or "").replace("Z","+00:00"))).total_seconds()
        except (TypeError, ValueError):
            age=999
        # A recent /run already processes ALL preparing/update items.
        if 0<=age<90 and old.get("executor")=="pc_chat_ttendencias_dedicated":
            print("TT_TRENDS_PREPARE_EXISTING_EDITORIAL_RUN",old.get("command_id"))
            return old.get("command_id")
        cid="tr-"+str(int(time.time()*1000))+"-manual"
        doc={"version":2,"command_id":cid,
             "requested_at":current.isoformat(timespec="milliseconds").replace("+00:00","Z"),
             "mode":"manual_pc_chat","executor":"pc_chat_ttendencias_dedicated",
             "project":"ttendencias","launcher_arg":"tendencias",
             "task":"editorial","auto_image_followup":False}
        url=endpoint.split("?")[0]
        payload={"branch":BRANCH,"sha":previous["sha"],
                 "message":"TTendencias: preparar novedad lanza misma pasada editorial Top10 "+cid,
                 "content":base64.b64encode((json.dumps(doc,ensure_ascii=False,indent=2)+"\n").encode()).decode()}
        try:
            api(url,token,payload,method="PUT")
            print("TT_TRENDS_PREPARE_PC_EDITORIAL_TRIGGERED",cid)
            return cid
        except urllib.error.HTTPError as error:
            if error.code not in {409,422} or attempt==4:
                raise
            time.sleep(0.4*(attempt+1))
    raise RuntimeError("Cannot request editorial trigger")

def test():
    from tempfile import TemporaryDirectory
    with TemporaryDirectory() as temp:
        q=Path(temp)/"queue.json"
        d=Path(temp)/"direct.txt"
        assert not is_new_request(str(q),str(d))
        q.write_text(json.dumps([{"ok":True,"message":MARKER+" Gularte"}]))
        assert is_new_request(str(q),str(d))
        q.write_text(json.dumps([{"ok":True,"message":"TTendencias: ya está en elaboración: Gularte"}]))
        assert not is_new_request(str(q),str(d))
        d.write_text(MARKER+" Gularte")
        assert is_new_request(str(q),str(d))
        d.write_text("TTendencias: Ferran vuelve a En elaboración (r2)")
        assert is_new_request(str(q),str(d))
        q.write_text(json.dumps([{"ok":True,"message":"TTendencias: Ferran vuelve a En elaboración (r2)"}]))
        assert is_new_request(str(q),str(d))
    print("TT_TRENDS_MANUAL_PREPARE_TRIGGER_SELFTEST_OK")

if __name__=="__main__":
    if "--selftest" in sys.argv:
        test()
    elif "--trigger" in sys.argv[1:] or is_new_request():
        trigger(os.environ["GH_TOKEN"])
    else:
        print("TT_TRENDS_MANUAL_PREPARE_NO_NEW_REQUEST")
