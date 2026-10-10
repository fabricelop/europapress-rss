#!/usr/bin/env python3
"""Comandos TT enviados desde Telegram privado o GitHub Issues, validados y autorizados.
Sin Cloudflare, Vercel, tokens embebidos en Pages ni generación automática de imágenes.
Solo lo ejecuta el workflow GitHub con actor == fabricelop.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OWNER = "fabricelop"
TERMINAL = {"published", "deleted", "dismissed", "removed"}


def load(path, default):
    full = ROOT / path
    try:
        return json.loads(full.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def save(path, obj):
    full = ROOT / path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def field(body, title):
    m = re.search(r"(?m)^### " + re.escape(title) + r"\s*\n+(.+?)(?=\n### |\Z)", body, flags=re.S)
    if not m:
        return ""
    value = m.group(1).strip()
    return "" if value == "_No response_" else value


def parse_issue(event):
    issue = event.get("issue") or {}
    author = (issue.get("user") or {}).get("login")
    sender = (event.get("sender") or {}).get("login")
    if author != OWNER or sender != OWNER:
        raise ValueError("Autor no autorizado")
    if not str(issue.get("title") or "").startswith("[TT-MOVIL]"):
        raise ValueError("No es un comando TT móvil")
    body = str(issue.get("body") or "")
    project = field(body, "Proyecto")
    action = field(body, "Acción")
    element_id = field(body, "ID del elemento")
    context = field(body, "Titular o contexto")[:300]
    instruction = field(body, "Instrucciones para reelaborar (opcional)")[:1000]
    if project not in {"ttittulares", "ttendencias"}:
        raise ValueError("Proyecto desconocido")
    if action not in {"published", "deleted", "rework", "prepare"}:
        raise ValueError("Acción no admitida")
    if not re.fullmatch(r"[\w#.\- ]{1,120}", element_id):
        raise ValueError("Identificador inválido")
    return project, action, element_id, context, instruction


def parse_dispatch(event):
    """Only repository owner may dispatch this workflow via GitHub OAuth PAT."""
    if os.environ.get("GITHUB_ACTOR") != OWNER:
        raise ValueError("Workflow dispatch no autorizado")
    inp = event.get("inputs") or {}
    project = str(inp.get("project") or "")
    action = str(inp.get("action") or "")
    element_id = str(inp.get("id") or "").strip()
    if project not in {"ttittulares", "ttendencias"}:
        raise ValueError("Proyecto no autorizado")
    if action not in {"published", "deleted", "rework", "prepare"}:
        raise ValueError("Acción no autorizada")
    if not re.fullmatch(r"[\w#.\- ]{1,120}", element_id):
        raise ValueError("ID no admitido")
    return project, action, element_id, str(inp.get("context") or "")[:300], str(inp.get("instruction") or "")[:1000]


def timestamp():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def matches(row, element_id):
    eid = element_id.casefold()
    return any(str(row.get(key) or "").casefold() == eid for key in
               ("event_id", "id", "name", "title", "display_name", "term_normalized"))


def tti_command(action, element_id, context, instruction, now):
    p = "ttittulares/prepared.json"
    prepared = load(p, {"project": "TTiTTulares", "items": []})
    rows = prepared.get("items") or []
    status = load("ttittulares/status.json", {})
    ledger_path = "telegram/ttittulares-deliveries.json"
    ledger = load(ledger_path, {"items": []})
    decisions_path = "ttittulares/decisions.json"
    decisions = load(decisions_path, {"project": "TTiTTulares", "items": []})
    existed = (any(matches(r, element_id) for r in rows) or
               any(matches(r, element_id) for r in ledger.get("items", [])) or
               any(matches(r, element_id) for r in status.get("processing_items", [])) or
               any(matches(r, element_id) for r in status.get("problematic_items", [])) or
               any(matches(r, element_id) for r in status.get("three_source_items", [])))
    if not existed:
        raise ValueError("No se encontró el evento TTiTTulares en el estado actual")
    existing = next((x for x in decisions.get("items", []) if matches(x, element_id)), None)
    if existing and str(existing.get("status") or "").lower() in TERMINAL:
        raise ValueError("Evento ya cerrado: " + str(existing.get("status")))
    if action in {"published", "deleted"}:
        row = existing or {"event_id": element_id}
        if existing is None:
            decisions.setdefault("items", []).append(row)
        row.update(status=action, updated_at=now, decision_source="github_pages_authorized_issue")
        row["published_at" if action == "published" else "deleted_at"] = now
        decisions["updated_at"] = now
        save(decisions_path, decisions)
        prepared["items"] = [x for x in rows if not matches(x, element_id)]
        prepared["count"] = len(prepared["items"])
        prepared["updated_at"] = now
        save(p, prepared)
        if action == "deleted":
            queue_path = "telegram/delete-message-queue.json"
            queue = load(queue_path, {"version": 1, "items": []})
            queued = {int(x.get("message_id") or 0) for x in queue.get("items", [])}
            for x in ledger.get("items", []):
                if not matches(x, element_id):
                    continue
                for key in ("telegram_message_id", "archive_telegram_message_id", "cross_quote_message_id"):
                    mid = int(x.get(key) or 0)
                    if mid > 0 and mid not in queued:
                        queue.setdefault("items", []).append({
                            "event_id": element_id, "message_id": mid,
                            "status": "pending", "reason": "github_pages_authorized_issue",
                            "created_at": now})
                        queued.add(mid)
                x["status"] = "deleted"
                x["deleted_at"] = now
            queue["updated_at"] = now
            save(queue_path, queue)
        else:
            for x in ledger.get("items", []):
                if matches(x, element_id) and x.get("status") == "sent":
                    x["status"] = "published"
                    x["published_at"] = now
        ledger["updated_at"] = now
        save(ledger_path, ledger)
        return "TTiTTulares: " + ("publicada" if action == "published" else "borrada y borrado Telegram en cola") + ": " + element_id
    if action not in {"rework", "prepare"}:
        raise ValueError("Acción no implementada")
    # Reutilizar la cola editorial real; NO iniciar ImageGen ni lanzar el PC.
    processing_path = "telegram/editorial-processing.json"
    processing = load(processing_path, {"items": []})
    record = next((r for r in processing.get("items", []) if matches(r, element_id)), None)
    ready = next((r for r in rows if matches(r, element_id)), None)
    if record is None:
        record = {"event_id": element_id}
        processing.setdefault("items", []).append(record)
    if not instruction and action == "rework":
        instruction = "Reelaborar el texto y el remate editorial manteniendo los hechos verificados."
    record.update(status="PROCESSING", selected_at=now, selection_mode="GITHUB_PAGES_MANUAL",
                  rewrite_instruction=instruction, title=str(ready.get("title") if ready else context or record.get("title") or "Noticia"),
                  revision=max(1, int(record.get("revision") or 0) + 1))
    processing["updated_at"] = now
    save(processing_path, processing)
    # Eliminar la versión lista para que reaparezca solo cuando exista una nueva.
    if ready:
        prepared["items"] = [x for x in rows if not matches(x, element_id)]
        prepared["count"] = len(prepared["items"])
        prepared["updated_at"] = now
        save(p, prepared)
    return "TTiTTulares: nueva petición registrada en la cola editorial " + element_id


def trend_command(action, element_id, context, instruction, now):
    p = "trends/requests.json"
    doc = load(p, {"requests": []})
    requests = doc.setdefault("requests", [])
    r = next((x for x in requests if matches(x, element_id)), None)
    deliveries_path = "trends/telegram-image-deliveries.json"
    deliveries = load(deliveries_path, {"items": []})
    msg = [x for x in deliveries.get("items", []) if matches(x, element_id)]
    existing = r is not None or bool(msg)
    if not existing:
        recent = load("trends/recent.json", {"items": []})
        existing = any(matches(x, element_id) for x in recent.get("items", []))
    if not existing:
        raise ValueError("Tendencia inexistente")
    dpath = "trends/mobile-decisions.json"
    decisions = load(dpath, {"items": []})
    decided = next((x for x in decisions["items"] if matches(x, element_id)), None)
    if decided and str(decided.get("status") or "") in TERMINAL:
        raise ValueError("Tendencia ya cerrada")
    if action in {"published", "deleted"}:
        if decided is None:
            decided = {"id": element_id}
            decisions["items"].append(decided)
        decided.update(status=action, updated_at=now, source="github_pages_authorized_issue")
        decisions["updated_at"] = now
        save(dpath, decisions)
        if r is not None:
            r["status"] = action
            r["updated_at"] = now
            doc["updated_at"] = now
            save(p, doc)
        for delivery in msg:
            if str(delivery.get("status") or "") != "sent":
                continue
            delivery["status"] = "published" if action == "published" else "delete_pending"
            delivery["updated_at"] = now
            if action == "published":
                delivery["published_at"] = now
        deliveries["updated_at"] = now
        save(deliveries_path, deliveries)
        return "TTendencias: " + ("publicada" if action == "published" else "borrado Telegram en cola") + ": " + element_id
    if r is None:
        r = {"id": element_id, "name": context or element_id}
        requests.append(r)
    r.update(status="preparing", requested_at=now, revision=int(r.get("revision") or 0) + 1,
             auto_queued=False, request_source="github_pages_authorized_issue",
             reexplain_instructions=instruction or "Reexplicar con los hechos verificados, sin generar imágenes.")
    doc["updated_at"] = now
    save(p, doc)
    return "TTendencias: petición de explicación registrada: " + element_id


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Use: python tt_mobile_issue_command.py <event.json>")
    event = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    project, action, element_id, context, instruction = (parse_dispatch(event) if "inputs" in event else parse_issue(event))
    now = timestamp()
    result = (tti_command if project == "ttittulares" else trend_command)(action, element_id, context, instruction, now)
    print("TT_MOBILE_COMMAND_OK " + result)
    Path("/tmp/tt-mobile-issue-result.txt").write_text(result + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
