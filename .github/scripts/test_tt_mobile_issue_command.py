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
    assert "ya realizada" in m.tti_command("deleted","abcdef123456","","","2026-10-10T16:10:00Z")
    assert len(get(m.ROOT,"telegram/delete-message-queue.json")["items"])==1
    try:m.tti_command("published","abcdef123456","","","2026-10-10T16:10:00Z");raise AssertionError("Closed record modified")
    except ValueError:pass
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    path="ttittulares/tremending/items.json"
    keep={"id":"tremending-aaa111","title":"Noticia de Público","status":"pending","url":"https://www.publico.es/tremending/example"}
    other={"id":"tremending-bbb222","title":"Otra noticia","status":"pending"}
    put(m.ROOT,path,{"project":"TTiTTulares","items":[keep,other],"scan":{"seen_urls":[keep["url"]]}})
    response=m.tti_command("deleted","tremending-aaa111","","","2026-10-11T00:00:00Z")
    assert "borrada del panel" in response
    saved=get(m.ROOT,path)
    assert saved["items"][0]["status"]=="deleted"
    assert saved["items"][0]["deleted_at"]=="2026-10-11T00:00:00Z"
    assert saved["items"][1]==other
    assert saved["scan"]["seen_urls"]==[keep["url"]]
    assert not (m.ROOT/"telegram/delete-message-queue.json").exists()
    assert "ya borrada" in m.tti_command("deleted","tremending-aaa111","","","2026-10-11T00:01:00Z")
    try:
        m.tti_command("rework","tremending-bbb222","","","2026-10-11T00:01:00Z")
        raise AssertionError("Tremending must not join editorial rework")
    except ValueError:pass
    try:
        m.tti_command("deleted","tremending-unknown","","","2026-10-11T00:01:00Z")
        raise AssertionError("Unknown Tremending ID accepted")
    except ValueError:pass

with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":"abc123xyz","name":"Tendencia verificada","revision":1,"status":"explained"}]})
    put(m.ROOT,"trends/telegram-image-deliveries.json",{"items":[{"event_id":"abc123xyz","status":"sent","telegram_message_id":45679}]})
    m.trend_command("deleted","abc123xyz","","","2026-10-10T16:00:00Z")
    assert get(m.ROOT,"trends/mobile-decisions.json")["items"][0]["status"]=="deleted"
    assert get(m.ROOT,"trends/telegram-image-deliveries.json")["items"][0]["status"]=="delete_pending"
    assert "ya realizada" in m.trend_command("deleted","abc123xyz","","","2026-10-10T16:10:00Z")
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":"abc123xyz","name":"Tendencia verificada","revision":1,"status":"explained"}]})
    m.trend_command("rework","abc123xyz","","Cambiar remate","2026-10-10T16:00:00Z")
    new=get(m.ROOT,"trends/requests.json")["requests"][0]
    assert new["revision"]==2 and new["status"]=="preparing"
    assert new["reexplain_instructions"]=="Cambiar remate"
with tempfile.TemporaryDirectory() as tmp:
    import os
    m.ROOT=Path(tmp)
    put(m.ROOT,"ttittulares/prepared.json",{"items":[{"event_id":"abcdef123456","title":"Caso de prueba cola"}]})
    put(m.ROOT,"ttittulares/status.json",{"processing_items":[]})
    put(m.ROOT,"telegram/ttittulares-deliveries.json",{"items":[{"event_id":"abcdef123456","status":"sent","telegram_message_id":45678}]})
    put(m.ROOT,"telegram/tt-mobile-command-queue.json",{"version":1,"items":[{"update_id":123456,
        "project":"ttittulares","action":"deleted","id":"abcdef123456","status":"pending",
        "cleanup_command_mid":777,"cleanup_notice_mid":778}]})
    before=os.environ.get("GITHUB_ACTOR")
    os.environ["GITHUB_ACTOR"]="fabricelop"
    try:
        assert m.process_queue()==1
        result=json.loads(Path("/tmp/tt-mobile-queue-results.json").read_text(encoding="utf8"))[0]
        assert result["cleanup_command_mid"]==777 and result["cleanup_notice_mid"]==778
        assert m.process_queue()==0
        items=get(m.ROOT,"telegram/tt-mobile-command-queue.json")["items"]
        assert len(items)==1 and items[0]["status"]=="completed"
        assert get(m.ROOT,"ttittulares/decisions.json")["items"][0]["status"]=="deleted"
        assert get(m.ROOT,"telegram/delete-message-queue.json")["items"][0]["message_id"]==45678
        try:
            os.environ["GITHUB_ACTOR"]="somebody_else"
            m.parse_dispatch({"inputs":{"project":"ttittulares","action":"deleted","id":"abcdef123456"}})
            raise AssertionError("Unauthorized dispatch accepted")
        except ValueError:pass
    finally:
        if before is None:os.environ.pop("GITHUB_ACTOR",None)
        else:os.environ["GITHUB_ACTOR"]=before
# A manual action must resolve the original RSS/capture title by event ID.
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    eid="ceuta123"
    put(m.ROOT,"telegram/events.json",{"events":[{
        "id":eid,"canonical_title":"Titular real de Ceuta",
        "url":"https://example.org/ceuta",
        "appearances":[{"source":"laSexta","url":"https://example.org/ceuta"}]}]})
    put(m.ROOT,"ttittulares/status.json",{"processing_items":[{"event_id":eid,"title":"Noticia"}]})
    result=m.tti_command("prepare",eid,"Noticia","","2026-10-11T16:00:00Z")
    assert "petición registrada" in result
    stored=get(m.ROOT,"telegram/editorial-processing.json")["items"][0]
    assert stored["title"]=="Titular real de Ceuta"
    assert stored["url"]=="https://example.org/ceuta"
    assert stored["source"]=="laSexta"
    assert stored["status"]=="PROCESSING"
    queued=get(m.ROOT,"ttittulares/editorial-queue.json")
    assert queued["count"]==1 and queued["items"][0]["title"]=="Titular real de Ceuta"
    visible=get(m.ROOT,"ttittulares/status.json")
    assert visible["processing_count"]==1 and visible["processing_items"][0]["title"]=="Titular real de Ceuta"
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"ttittulares/status.json",{"processing_items":[{"event_id":"unknown","title":"Noticia"}]})
    try:
        m.tti_command("prepare","unknown","Noticia","","2026-10-11T16:00:00Z")
        raise AssertionError("A generic headline was incorrectly accepted")
    except ValueError as exc:
        assert "Titular auténtico" in str(exc)
    assert not (m.ROOT/"telegram/editorial-processing.json").exists()

# Top 11-30 are displayed automatically, but only enter the editorial
# queue on the editor's authenticated Prepare novelty command.
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[]})
    put(m.ROOT,"trends/recent.json",{"items":[
        {"name":"Gularte","rank":22},{"name":"#Tema Con Espacios","rank":26}]})
    response=m.trend_command("prepare","Gularte","","","2026-10-11T22:20:00Z")
    assert "registrada" in response
    req=get(m.ROOT,"trends/requests.json")["requests"][0]
    queue=get(m.ROOT,"trends/editorial-queue.json")["items"]
    assert req["status"]=="preparing" and req["rank"]==22 and req["auto_queued"] is False
    assert req["with_image"] is True and req["disable_ai_image"] is False
    assert queue[0]["with_image"] is True and queue[0]["disable_ai_image"] is False
    assert len(queue)==1 and queue[0]["id"]==req["id"]
    assert queue[0]["rank"]==22 and queue[0]["auto_queued"] is False
    result=m.trend_command("prepare","#Tema Con Espacios","","","2026-10-11T22:20:01Z")
    items=get(m.ROOT,"trends/requests.json")["requests"]
    assert len(items)==2 and items[1]["name"]=="#Tema Con Espacios"
    assert len(items[1]["id"])==12 and " " not in items[1]["id"]
    assert len(get(m.ROOT,"trends/editorial-queue.json")["items"])==2
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    eid="abc123dismiss"
    put(m.ROOT,"ttittulares/prepared.json",{"items":[]})
    put(m.ROOT,"ttittulares/status.json",{"processing_items":[{"event_id":eid}]})
    put(m.ROOT,"ttittulares/editorial-queue.json",{"items":[{"event_id":eid,"status":"PROCESSING"}],"count":1})
    put(m.ROOT,"telegram/editorial-processing.json",{"items":[{"event_id":eid,"status":"PROCESSING"}]})
    result=m.tti_command("dismissed",eid,"","","2026-10-17T17:30:00Z")
    assert "desestimada" in result
    assert get(m.ROOT,"ttittulares/decisions.json")["items"][0]["status"]=="dismissed"
    assert get(m.ROOT,"ttittulares/editorial-queue.json")["items"][0]["status"]=="DISMISSED"
    assert get(m.ROOT,"ttittulares/editorial-queue.json")["count"]==0
    assert get(m.ROOT,"telegram/editorial-processing.json")["items"][0]["status"]=="DISMISSED"
    assert "ya realizada" in m.tti_command("dismissed",eid,"","","2026-10-17T17:31:00Z")
# Desestimar una tendencia pendiente no la publica ni genera entregas en Telegram.
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    eid="trenddismiss123"
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":eid,"name":"Tendencia de prueba","status":"preparing","revision":1}]})
    put(m.ROOT,"trends/editorial-queue.json",{"items":[{"id":eid,"name":"Tendencia de prueba","status":"preparing"}],"count":1})
    result=m.trend_command("dismissed",eid,"","","2026-10-17T19:30:00Z")
    assert "desestimada" in result
    assert get(m.ROOT,"trends/editorial-queue.json")["items"][0]["status"]=="dismissed"
    assert get(m.ROOT,"trends/editorial-queue.json")["count"]==0
    assert get(m.ROOT,"trends/requests.json")["requests"][0]["status"]=="dismissed"
    assert get(m.ROOT,"trends/mobile-decisions.json")["items"][0]["status"]=="dismissed"
    assert not (m.ROOT/"trends/telegram-image-deliveries.json").exists()
    assert "ya realizada" in m.trend_command("dismissed",eid,"","","2026-10-17T19:31:00Z")
# Browser issue links can contain legitimate punctuation in a trend name.
# Never accept newline/control injection or enqueue outside Top 11-30.
owner={"user":{"login":"fabricelop"}}
name="#Tema: edición / España"
body="### Proyecto\n\nttendencias\n\n### Acción\n\nprepare\n\n### ID del elemento\n\n"+name+"\n\n### Titular o contexto\n\n"+name+"\n"
parsed=m.parse_issue({"sender":{"login":"fabricelop"},"issue":{**owner,"title":"[TT-MOVIL] ttendencias prepare","body":body}})
assert parsed[:3]==("ttendencias","prepare",name)
try:
    m.parse_issue({"sender":{"login":"fabricelop"},"issue":{**owner,"title":"[TT-MOVIL] bad","body":body.replace(name,name+"\nmalicious",1)}})
    raise AssertionError("Newline injection accepted")
except ValueError:pass
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    put(m.ROOT,"trends/requests.json",{"requests":[]})
    put(m.ROOT,"trends/recent.json",{"items":[{"rank":10,"name":"Top10"},{"rank":11,"name":name},{"rank":30,"name":"Treinta"},{"rank":31,"name":"Fuera"}]})
    response=m.trend_command("prepare",name,name,"","2026-10-18T08:00:00Z")
    assert "registrada" in response
    request=get(m.ROOT,"trends/requests.json")["requests"][0]
    queue=get(m.ROOT,"trends/editorial-queue.json")
    assert request["name"]==name and request["status"]=="preparing" and request["rank"]==11
    assert queue["count"]==1 and queue["items"][0]["id"]==request["id"] and queue["items"][0]["status"]=="preparing"
    assert "ya está en elaboración" in m.trend_command("prepare",name,name,"","2026-10-18T08:00:10Z")
    assert len(get(m.ROOT,"trends/requests.json")["requests"])==1
    for outside in ("Top10","Fuera"):
        try:m.trend_command("prepare",outside,outside,"","2026-10-18T08:00:10Z");raise AssertionError("Out-of-range trend queued")
        except ValueError:pass
    assert len(get(m.ROOT,"trends/requests.json")["requests"])==1
# An old Listas card must be erased and its normal photo invalidated
# when requesting fresh elaboration through authenticated GitHub Pages.
with tempfile.TemporaryDirectory() as tmp:
    m.ROOT=Path(tmp)
    eid="ferran-ready"
    old_image="https://example.test/ferran-old.jpg"
    put(m.ROOT,"trends/requests.json",{"requests":[{"id":eid,"name":"Ferran",
        "status":"explained","revision":3,"explanation":"Resultado viejo",
        "archive_image":{"url":old_image},"explained_at":"2026-10-20T20:00:00Z"}]})
    put(m.ROOT,"trends/telegram-manual-explained.json",{"items":[{
        "id":eid,"name":"Ferran","status":"explained","revision":3,
        "explanation":"Resultado viejo","explained_at":"2026-10-20T20:00:00Z",
        "fallback_image":{"url":old_image}}]})
    put(m.ROOT,"trends/prepared.json",{"items":[{"id":eid,"image":{"url":old_image}}]})
    result=m.trend_command("rework",eid,"","","2026-10-20T23:00:00Z")
    assert "vuelve a En elaboración" in result
    assert get(m.ROOT,"trends/telegram-manual-explained.json")["items"]==[]
    assert get(m.ROOT,"trends/prepared.json")["items"]==[]
    req=get(m.ROOT,"trends/requests.json")["requests"][0]
    assert req["revision"]==4 and req["status"]=="preparing"
    assert "explanation" not in req and "archive_image" not in req
    assert req["fallback_image_status"]=="pending"
    rows=get(m.ROOT,"trends/editorial-queue.json")["items"]
    assert len(rows)==1 and rows[0]["revision"]==4
    try:
        m.trend_command("rework",eid,"","","2026-10-20T23:01:00Z")
        raise AssertionError("Obsolete Listas card unexpectedly reworked again")
    except ValueError:pass
print("TT_MOBILE_ISSUE_FIXTURES_OK")
