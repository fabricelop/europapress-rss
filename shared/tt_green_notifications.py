#!/usr/bin/env python3
"""One quiet-to-green Telegram alert per verified ChatGPT Images prompt.

Editorial Telegram cards and archival photographs are delivered silently by
telegram_readonly_delivery.py. This notifier runs ONLY from the serialized
pinned-index workflow, after its panel updates. It never generates images,
posts an article twice, alters buttons, or claims raster completion.
"""
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import telegram_pinned_index as panel

IMAGE_URL="https://chatgpt.com/images"
SEEN_CAP=2500


def green_key(row):
    return (str(row.get("id") or "")+":"+
            str(int(row.get("rev") or 0))+":"+
            str(int(row.get("mid") or 0)))


def news_label(project,row,details):
    fact=panel.one_line_sentence(project,row.get("title"),details.get("sentence"),65)
    remate=details.get("remate") or panel.extract_remate(details.get("sentence"))
    return fact,remate


def notify(project,send=None,details=None,rows=None,now=None):
    """Send a single digest ONLY for newly verified green entries.

    First run deliberately baselines existing greens: deploying the feature
    must not wake the user for an archive of old image launches.
    """
    conf=panel.PROJECTS[project]
    send=send or panel.telegram
    now=now or datetime.now(timezone.utc)
    if rows is None:
        rows,_=panel.active_records(project)
    if details is None:
        details=panel.image_statuses_for_panel(project,rows)
    state=panel.read(conf["state"],{})
    seen=list(state.get("green_notification_seen") or [])
    seen_set=set(seen)
    greens=[]
    for row in rows:
        info=details.get(row["id"]) or {}
        if not isinstance(info,dict) or info.get("status")!="launched":
            continue
        if not int(row.get("mid") or 0):
            continue
        greens.append((green_key(row),row,info))
    fresh=[x for x in greens if x[0] not in seen_set]
    state["green_notifier_checked_at"]=now.isoformat()

    if state.get("green_notifications_initialized") is not True:
        # Do not retroactively notify existing images after deployment.
        state["green_notifications_initialized"]=True
        for key,_,_ in greens:
            if key not in seen_set:
                seen.append(key);seen_set.add(key)
        state["green_notification_seen"]=seen[-SEEN_CAP:]
        panel.write(conf["state"],state)
        print("TT_GREEN_NOTIFY_BASELINE",project,"existing="+str(len(greens)),flush=True)
        return 0

    if not fresh:
        panel.write(conf["state"],state)
        print("TT_GREEN_NOTIFY_NO_NEW",project,flush=True)
        return 0

    token=os.environ.get(conf["bot_token"],"")
    chat=os.environ.get(conf["chat"],"")
    if project=="ttendencias":
        chat=chat or panel.read("trends/telegram-bot-state.json",{}).get("chat_id")
    if not token or not chat:
        raise RuntimeError("Private Telegram credentials missing for green notifier "+project)

    # A single notification for all newly confirmed launches in this pass.
    # Editing the existing news card would not itself trigger a phone alert.
    lines=["🟢 "+conf["label"]+": "+
           ("1 imagen IA enviada a ChatGPT Images" if len(fresh)==1 else
            str(len(fresh))+" imágenes IA enviadas a ChatGPT Images")]
    for _,row,info in fresh[:12]:
        label,remate=news_label(project,row,info)
        lines.append("• "+label)
        if remate:lines.append("  "+remate)
    if len(fresh)>12:lines.append("… y "+str(len(fresh)-12)+" más en el panel fijado")
    text="\n".join(lines)
    if len(text)>3800:
        text=text[:3797]+"…"
    payload={
        "chat_id":str(chat),"text":text,
        "disable_notification":False,
        "link_preview_options":{"is_disabled":True},
        "reply_markup":{"inline_keyboard":[[
            {"text":"🎨 Abrir ChatGPT Images","url":IMAGE_URL}]]}
    }
    # A single new green is best shown as a reply to the original news card.
    if len(fresh)==1:
        payload["reply_to_message_id"]=int(fresh[0][1]["mid"])
        payload["allow_sending_without_reply"]=False
    result=send(token,"sendMessage",payload)
    if not isinstance(result,dict) or int(result.get("message_id") or 0)<=0:
        raise RuntimeError("Green notification was not accepted by Telegram")
    for key,_,_ in fresh:
        if key not in seen_set:
            seen.append(key);seen_set.add(key)
    state["green_notification_seen"]=seen[-SEEN_CAP:]
    state["green_notification_message_id"]=int(result["message_id"])
    state["green_notification_last_at"]=now.isoformat()
    panel.write(conf["state"],state)
    print("TT_GREEN_NOTIFY_SENT",project,"new="+str(len(fresh)),
          "message_id="+str(result["message_id"]),flush=True)
    return len(fresh)


def selftest():
    from tempfile import TemporaryDirectory
    saved=panel.ROOT
    old=os.environ.get("TELEGRAM_BOT_TOKEN")
    with TemporaryDirectory() as td:
        panel.ROOT=Path(td)
        try:
            for project in panel.PROJECTS:
                conf=panel.PROJECTS[project]
                os.environ[conf["bot_token"]]="test"
                os.environ[conf["chat"]]="123"
                panel.write(conf["state"],{"message_id":99,"pinned":True})
                a={"id":"news","rev":0 if project=="ttendencias" else 1,
                   "mid":901,"title":"La actualidad explicada"}
                b={"id":"other","rev":a["rev"],"mid":902,"title":"Otra noticia"}
                green={"news":{"status":"launched","sentence":
                   "La actualidad ha dado un giro. Continúan las reacciones.",
                   "remate":"🌶️ El giro tiene volante."},
                   "other":{"status":"queued"}}
                calls=[]
                def fake(token,method,payload):
                    calls.append((method,payload))
                    return {"message_id":1001}
                assert notify(project,fake,green,[a,b])==0
                assert calls==[], "initial greens must not generate backfill push"
                assert notify(project,fake,green,[a,b])==0
                green["other"]={"status":"launched","sentence":"Otra noticia confirmada.",
                                "remate":"🌶️ El trámite ya tiene cola."}
                assert notify(project,fake,green,[a,b])==1
                assert len(calls)==1
                assert calls[0][0]=="sendMessage"
                assert calls[0][1]["disable_notification"] is False
                assert calls[0][1]["reply_to_message_id"]==902
                assert "ChatGPT Images" in calls[0][1]["text"]
                assert notify(project,fake,green,[a,b])==0
                assert len(calls)==1, "must never re-notify same launch"
                # Deleted rows are not passed by active_records; no late ping.
                assert notify(project,fake,green,[a])==0
                # New revision is independently eligible.
                c={**a,"rev":a["rev"]+1}
                assert notify(project,fake,green,[c])==1
                assert len(calls)==2
            print("TT_GREEN_NOTIFY_SELFTEST_OK")
        finally:
            panel.ROOT=saved
            for name in ("TELEGRAM_BOT_TOKEN","TTENDENCIAS_BOT_TOKEN",
                         "TELEGRAM_CHAT_ID","TTENDENCIAS_CHAT_ID"):
                os.environ.pop(name,None)
            if old is not None:os.environ["TELEGRAM_BOT_TOKEN"]=old


if __name__=="__main__":
    if len(sys.argv)>1 and sys.argv[1]=="selftest":
        selftest()
    else:
        for name in panel.PROJECTS:
            notify(name)
