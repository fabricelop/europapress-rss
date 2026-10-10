#!/usr/bin/env python3
"""Fixture tests. Never touch live GitHub data or Telegram."""
import json
import tempfile
from pathlib import Path
from importlib.machinery import SourceFileLoader

m=SourceFileLoader("tt_mobile_issue_command",str(Path(__file__).with_name("tt_mobile_issue_command.py"))).load_module()
def put(root,p,d):
    out=root/p;out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(d),encoding="utf8")
def get(root,p):
    return json.loads((root/p).read_text(encoding="utf8"))

with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"ttittulares/prepared.json",{"items":[{"event_id":"abcdef123456","title":"Caso de prueba"}]})
    put(m.ROOT,"ttittulares/status.json",{"processing_items":[]})
    put(m.ROOT,"telegram/ttittulares-deliveries.json",{"items":[{"event_id":"abcdef123456","status":"sent","telegram_message_id":45678}]})
    assert "cola" in m.tti_command("deleted","abcdef123456","","","2026-10-10T16:00:00Z")
    assert get(m.ROOT,"ttittulares/decisions.json")["items"][0]["status"]=="deleted"
    assert get(m.ROOT,"ttittulares/prepared.json")["items"]==[]
    assert get(m.ROOT,"telegram/delete-message-queue.json")["items"][0]["message_id"]==45678
    try:m.tti_command("published","abcdef123456","","","2026-10-10T16:10:00Z");raise AssertionError("Closed record modified")
    except ValueError:pass
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":"abc123xyz","name":"Tendencia verificada","revision":1,"status":"explained"}]})
    put(m.ROOT,"trends/telegram-image-deliveries.json",{"items":[{"event_id":"abc123xyz","status":"sent","telegram_message_id":45679}]})
    m.trend_command("deleted","abc123xyz","","","2026-10-10T16:00:00Z")
    assert get(m.ROOT,"trends/mobile-decisions.json")["items"][0]["status"]=="deleted"
    assert get(m.ROOT,"trends/telegram-image-deliveries.json")["items"][0]["status"]=="delete_pending"
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":"abc123xyz","name":"Tendencia verificada","revision":1,"status":"explained"}]})
    m.trend_command("rework","abc123xyz","","Cambiar remate","2026-10-10T16:00:00Z")
    new=get(m.ROOT,"trends/requests.json")["requests"][0]
    assert new["revision"]==2 and new["status"]=="preparing"
    assert new["reexplain_instructions"]=="Cambiar remate"
print("TT_MOBILE_ISSUE_FIXTURES_OK")
