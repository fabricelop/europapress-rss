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
    if action not in {"published", "deleted", "dismissed", "rework", "prepare"}:
        raise ValueError("Acción no admitida")
    if not re.fullmatch(r"[^\x00-\x1f\x7f]{1,120}", element_id):
        raise ValueError("Identificador inválido")
    return project, action, element_id, context, instruction


def parse_dispatch(event, trusted_queue=False):
    """Direct commands require owner; native-receiver queue is preauthorized.

    The queue must only be written by the authenticated private Telegram bot.
    GitHub Actions uses its own bot actor to dispatch that trusted queue.
    """
    if not trusted_queue and os.environ.get("GITHUB_ACTOR") != OWNER:
        raise ValueError("Workflow dispatch no autorizado")
    inp = event.get("inputs") or {}
    project = str(inp.get("project") or "")
    action = str(inp.get("action") or "")
    element_id = str(inp.get("id") or "").strip()
    if project not in {"ttittulares", "ttendencias"}:
        raise ValueError("Proyecto no autorizado")
    if action not in {"published", "deleted", "dismissed", "rework", "prepare"}:
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



def original_news_metadata(element_id, *rows):
    """Resolve genuine news capture metadata; never trust a generic UI label."""
    candidates = [r for r in rows if isinstance(r, dict)]
    for path, fields in (
        ("telegram/events.json", ("events",)),
        ("ttittulares/editorial-queue.json", ("items",)),
        ("ttittulares/status.json", ("processing_items", "problematic_items", "three_source_items")),
        ("telegram/editorial-processing.json", ("items",)),
    ):
        doc = load(path, {})
        for field in fields:
            candidates.extend(r for r in doc.get(field, [])
                              if isinstance(r, dict) and
                              str(r.get("event_id") or r.get("id") or "") == element_id)
    generic = {"", "noticia", "sin título", "sin titulo", "actualidad", "titular pendiente"}
    title = next((t for r in candidates
                  if (t := str(r.get("canonical_title") or r.get("title") or "").strip())
                  and t.casefold().strip(" .:–-") not in generic), "")
    url = next((u for r in candidates
                if (u := str(r.get("url") or "").strip()).startswith("https://")), "")
    appearance = next((a for r in candidates for a in (r.get("appearances") or [])
                       if isinstance(a, dict) and a.get("source") and
                       str(a.get("url") or "").startswith("https://")), {})
    if not url:
        url = str(appearance.get("url") or "")
    source = next((str(a.get("source")) for r in candidates for a in (r.get("appearances") or [])
                   if isinstance(a, dict) and str(a.get("url") or "") == url and a.get("source")), "")
    if not source:
        source = str(appearance.get("source") or "")
    if not source:
        source = next((str(r.get("source") or "") for r in candidates if r.get("source")), "")
    return title, url, source


def tti_command(action, element_id, context, instruction, now):
    # Tremending is a curated external-news list, not a TTiTTulares editorial
    # event. Deleting an entry hides it persistently; it must not be sent into
    # the editorial delete-message queue or modify other TTiTTulares entries.
    if element_id.startswith("tremending-"):
        if action != "deleted":
            raise ValueError("Tremending solo permite borrar entradas")
        path = "ttittulares/tremending/items.json"
        tremending = load(path, {"project": "TTiTTulares", "items": []})
        row = next((x for x in tremending.get("items", [])
                    if str(x.get("id") or "") == element_id), None)
        if row is None:
            raise ValueError("Entrada Tremending no encontrada")
        if str(row.get("status") or "").lower() in {"deleted", "dismissed"}:
            return "Tremending: entrada ya borrada: " + element_id
        row.update(status="deleted", deleted_at=now, updated_at=now,
                   decision_source="github_pages_authorized_issue")
        tremending["updated_at"] = now
        save(path, tremending)
        return "Tremending: borrada del panel: " + element_id
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
               any(matches(r, element_id) for r in status.get("three_source_items", [])) or
               any(matches(r, element_id) for r in load("ttittulares/editorial-queue.json", {"items": []}).get("items", [])))
    existing = next((x for x in decisions.get("items", []) if matches(x, element_id)), None)
    if existing and str(existing.get("status") or "").lower() in TERMINAL:
        previous = str(existing.get("status") or "").lower()
        if previous == action:
            return "TTiTTulares: acción ya realizada anteriormente (" + action + "): " + element_id
        raise ValueError("Evento ya cerrado: " + previous)
    if not existed:
        raise ValueError("No se encontró el evento TTiTTulares en el estado actual")
    if action == "dismissed":
        queue_path = "ttittulares/editorial-queue.json"
        queue = load(queue_path, {"items": []})
        active = next((x for x in queue.get("items", []) if matches(x, element_id)
                       and str(x.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}), None)
        if active is None:
            raise ValueError("La noticia ya no consta en elaboración")
        active.update(status="DISMISSED", dismissed_at=now,
                      decision_source="github_pages_authorized_issue")
        queue["count"] = sum(str(x.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}
                             for x in queue.get("items", []))
        queue["updated_at"] = now
        save(queue_path, queue)
        processing_path = "telegram/editorial-processing.json"
        processing = load(processing_path, {"items": []})
        for item in processing.get("items", []):
            if matches(item, element_id):
                item.update(status="DISMISSED", dismissed_at=now,
                            decision_source="github_pages_authorized_issue")
        processing["updated_at"] = now
        save(processing_path, processing)
        row = existing or {"event_id": element_id}
        if existing is None:
            decisions.setdefault("items", []).append(row)
        row.update(status="dismissed", dismissed_at=now, updated_at=now,
                   decision_source="github_pages_authorized_issue")
        decisions["updated_at"] = now
        save(decisions_path, decisions)
        return "TTiTTulares: desestimada en la cola editorial: " + element_id
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
    title, url, source = original_news_metadata(element_id, ready, record)
    if not title:
        # Keep existing state untouched; do not persist anonymous new records.
        raise ValueError("Titular auténtico no disponible en la captura; solicitud no enviada")
    record.update(status="PROCESSING", selected_at=now, selection_mode="GITHUB_PAGES_MANUAL",
                  rewrite_instruction=instruction, title=title,
                  revision=max(1, int(record.get("revision") or 0) + 1))
    if url:
        record["url"] = url
    if source:
        record["source"] = source
    processing["updated_at"] = now
    save(processing_path, processing)
    # Make the editorial state visible immediately in both mobile panels.
    queue_path = "ttittulares/editorial-queue.json"
    queue = load(queue_path, {"project": "TTiTTulares", "items": []})
    queue_row = next((x for x in queue.get("items", []) if matches(x, element_id)), None)
    if queue_row is None:
        queue_row = {"event_id": element_id}
        queue.setdefault("items", []).append(queue_row)
    queue_row.update(title=title, status="PROCESSING", revision=record["revision"],
                     selected_at=now, selection_mode="GITHUB_PAGES_MANUAL",
                     rewrite_request=instruction, with_image=True,
                     image_mode="ai_plus_fallback")
    if url:
        queue_row["url"] = url
    if source:
        queue_row["source"] = source
    queue["count"] = sum(str(x.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}
                         for x in queue["items"])
    queue["updated_at"] = now
    save(queue_path, queue)
    visible = status.setdefault("processing_items", [])
    visible_row = next((x for x in visible if matches(x, element_id)), None)
    if visible_row is None:
        visible_row = {"event_id": element_id}
        visible.insert(0, visible_row)
    visible_row.update(title=title, selected_at=now,
                       selection_mode="GITHUB_PAGES_MANUAL", revision=record["revision"])
    if url:
        visible_row["url"] = url
    status["processing_count"] = len(visible)
    status["updated_at"] = now
    save("ttittulares/status.json", status)
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
    if decided and str(decided.get("status") or "") in TERMINAL and action != "rework":
        previous = str(decided.get("status") or "")
        if previous == action:
            return "TTendencias: acción ya realizada anteriormente (" + action + "): " + element_id
        raise ValueError("Tendencia ya cerrada")
    if action == "rework":
        # Listas -> En elaboración: borrar tarjeta y fotografía anteriores
        # antes de encolar una revisión completamente nueva.
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pilot"))
        from trends_rework import rework_explained, rework_top30
        manual_path = "trends/telegram-manual-explained.json"
        queue_path = "trends/editorial-queue.json"
        prepared_path = "trends/prepared.json"
        manual = load(manual_path, {"items": []})
        queue = load(queue_path, {"items": []})
        prepared = load(prepared_path, {"items": []})
        target_id = str(r.get("id") or element_id) if r else element_id
        ready = next((x for x in manual.get("items", []) if str(x.get("id") or "") == target_id
                      and str(x.get("status") or "").lower() == "explained"), None)
        try:
            if ready and str((r or {}).get("status") or "").lower() not in TERMINAL and not (decided and str(decided.get("status") or "") in TERMINAL):
                next_revision = rework_explained(
                    target_id, None, now, doc, manual, queue, decisions, deliveries,
                    "github_pages_authorized_issue_rework"
                )
                prepared["items"] = [row for row in prepared.get("items", [])
                                     if str(row.get("id") or "") != target_id]
            else:
                recent = load("trends/recent.json", {"items": []})
                new_id = rework_top30(
                    target_id, None, now, recent.get("items") or [],
                    doc, manual, queue, decisions, "github_pages_authorized_issue_rework"
                )
                next_revision = 0
        except ValueError as exc:
            raise ValueError(str(exc)) from exc
        prepared["updated_at"] = now
        for location, value in (
            (p, doc), (manual_path, manual), (queue_path, queue),
            (dpath, decisions), (deliveries_path, deliveries),
            (prepared_path, prepared),
        ):
            save(location, value)
        return "TTendencias: " + str(r.get("name") or element_id) + " vuelve a En elaboración (r" + str(next_revision) + ")"
    # Desestimar detiene la elaboración pendiente; nunca equivale a publicar.
    if action == "dismissed":
        queue_path = "trends/editorial-queue.json"
        queue = load(queue_path, {"items": []})
        active = next((x for x in queue.get("items", [])
                       if matches(x, element_id)
                       and str(x.get("status") or "").lower() in {"preparing", "update"}), None)
        if active is None:
            raise ValueError("La tendencia ya no consta en elaboración")
        active.update(status="dismissed", dismissed_at=now,
                      decision_source="github_pages_authorized_issue")
        queue["count"] = sum(str(x.get("status") or "").lower() in {"preparing", "update"}
                             for x in queue.get("items", []))
        queue["updated_at"] = now
        save(queue_path, queue)
        if r is not None:
            r.update(status="dismissed", dismissed_at=now, updated_at=now)
            doc["updated_at"] = now
            save(p, doc)
        if decided is None:
            decided = {"id": element_id, "name": str(active.get("name") or "")}
            decisions["items"].append(decided)
        decided.update(status="dismissed", dismissed_at=now, updated_at=now,
                       source="github_pages_authorized_issue")
        decisions["updated_at"] = now
        save(dpath, decisions)
        return "TTendencias: desestimada en la cola editorial: " + element_id
    # Manual Prepare behaves like a Top 10 editorial item, but is created
    # only once while that specific revision is already under investigation.
    if (action == "prepare" and r is not None and
            str(r.get("status") or "") in {"preparing", "update"}):
        return "TTendencias: ya está en elaboración: " + str(r.get("name") or element_id)
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
    recent = load("trends/recent.json", {"items": []})
    top_row = next((x for x in recent.get("items", [])[:30]
                    if matches(x, element_id) or
                    (r and str(x.get("name") or "").casefold()==
                     str(r.get("name") or "").casefold())), None)
    if action == "prepare" and r is None and (
            top_row is None or not 11 <= int(top_row.get("rank") or 0) <= 30):
        raise ValueError("Preparar novedad requiere una tendencia vigente del puesto 11 al 30")
    if r is None:
        # New 11-30 cards may use their visible name as the Telegram deep-link
        # ID. The editorial ID must be stable and safe for outbox filenames.
        import hashlib
        name = str((top_row or {}).get("name") or context or element_id)
        stable_id = element_id if re.fullmatch(r"[A-Za-z0-9_-]{3,80}",element_id) else hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]
        r = {"id": stable_id, "name": name}
        requests.append(r)
    if top_row:
        r["rank"] = int(top_row.get("rank") or r.get("rank") or 0)
        r["name"] = str(top_row.get("name") or r.get("name") or "")
    r.update(status="preparing", requested_at=now, revision=int(r.get("revision") or 0) + 1,
             auto_queued=False, request_source="github_pages_authorized_issue",
             task="explain", with_image=True, disable_ai_image=False,
             reexplain_instructions=instruction or "Investiga y explica esta tendencia con el mismo rigor que una Top 10. El texto y remate se cierran antes de las imágenes.")
    doc["updated_at"] = now
    save(p, doc)
    # Apply to the queue immediately instead of waiting for the Top 30 refresh.
    path = "trends/editorial-queue.json"
    queue = load(path, {"project": "TTendencias", "items": []})
    rows = [x for x in queue.get("items", []) if str(x.get("id") or "") != str(r["id"])]
    rows.append({
        "id": r["id"], "name": r["name"], "rank": r.get("rank"),
        "status": "preparing", "requested_at": now,
        "revision": r["revision"], "task": "explain",
        "auto_queued": False, "request_source": "github_pages_authorized_issue",
        "with_image": True, "disable_ai_image": False,
        "rewrite_instruction": r["reexplain_instructions"],
    })
    queue.update(project="TTendencias", items=rows,
                 count=sum(str(x.get("status") or "").lower() in {"preparing", "update"} for x in rows),
                 updated_at=now)
    save(path, queue)
    return "TTendencias: petición de explicación registrada: " + str(r["name"])



def process_queue():
    """Consume queued Telegram commands from a trusted, repository-owned commit.

    Updates are idempotent: completed/failed items are never replayed.
    The GitHub Actions commit includes the decision ledgers and queue receipt
    together, so a concurrent push retry starts from the latest main.
    """
    path = "telegram/tt-mobile-command-queue.json"
    queue = load(path, {"version": 1, "items": []})
    items = queue.get("items") or []
    if not isinstance(items, list):
        raise ValueError("Malformed Telegram command queue")
    results = []
    for item in items:
        if not isinstance(item, dict) or item.get("status") != "pending":
            continue
        action_id = str(item.get("update_id") or "")
        cleanup = {key:int(item.get(key) or 0) for key in
                   ("cleanup_command_mid","cleanup_notice_mid")
                   if str(item.get(key) or "").isdigit()}
        try:
            project, action, element_id, context, instruction = parse_dispatch(
                {"inputs": {"project": item.get("project"), "action": item.get("action"),
                            "id": item.get("id"), "context": "",
                            "instruction": item.get("instruction", "")}},
                trusted_queue=True
            )
            result = (tti_command if project == "ttittulares" else trend_command)(
                action, element_id, context, instruction, timestamp()
            )
            item.update(status="completed", completed_at=timestamp())
            item.pop("error", None)
            results.append({"update_id": action_id, "ok": True, "message": result, **cleanup})
        except Exception as exc:
            error = str(exc)[:180]
            item.update(status="failed", completed_at=timestamp(), error=error)
            results.append({"update_id": action_id, "ok": False,
                            "message": "No se completó la orden " + action_id + ": " + error, **cleanup})
    if results:
        queue["updated_at"] = timestamp()
        save(path, queue)
    Path("/tmp/tt-mobile-queue-results.json").write_text(
        json.dumps(results, ensure_ascii=False), encoding="utf-8"
    )
    print("TT_MOBILE_QUEUE_RESULTS", json.dumps(results, ensure_ascii=False))
    return len(results)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Use: python tt_mobile_issue_command.py <event.json>")
    if "--queue" in sys.argv[2:]:
        process_queue()
        return
    event = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    project, action, element_id, context, instruction = (parse_dispatch(event) if "inputs" in event else parse_issue(event))
    now = timestamp()
    result = (tti_command if project == "ttittulares" else trend_command)(action, element_id, context, instruction, now)
    print("TT_MOBILE_COMMAND_OK " + result)
    Path("/tmp/tt-mobile-issue-result.txt").write_text(result + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
