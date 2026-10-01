#!/usr/bin/env python3
import hashlib
import json
import unicodedata
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
MADRID = ZoneInfo("Europe/Madrid")
EXPLANATION_TTL = timedelta(hours=48)

def load(name, default):
    path = ROOT / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(name, obj):
    (ROOT / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def norm(value):
    text = unicodedata.normalize("NFD", str(value or ""))
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
    return " ".join(text.casefold().split())

def parse_timestamp(value):
    """Devuelve una fecha con zona horaria o None si el dato es inválido."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed.replace(tzinfo=MADRID) if parsed.tzinfo is None else parsed
    except (TypeError, ValueError):
        return None

def save_editorial_queue(requests_doc):
    recent_now = load("recent.json", {"items": []})
    top10_names = {norm(x.get("name")) for x in (recent_now.get("items") or [])[:10] if x.get("name")}
    active = []
    for req in requests_doc.get("requests", []) or []:
        status = str(req.get("status") or "")
        if status not in {"preparing", "update", "problematic"}:
            continue
        if status == "problematic" and norm(req.get("name")) not in top10_names:
            continue
        active.append({
            "id": req.get("id"),
            "name": req.get("name"),
            "rank": req.get("rank"),
            "status": req.get("status"),
            "requested_at": req.get("requested_at"),
            "revision": int(req.get("revision") or 0),
            "rewrite_instruction": req.get("rewrite_instruction") or req.get("rewrite_request") or "",
            "with_image": True,  # IA + fallback en paralelo; nunca bloquean la explicación.
            "task": "explain",
            "tremending_origin": bool(req.get("tremending_origin")),
            "tremending_id": req.get("tremending_id"),
            "article_title": req.get("article_title"),
            "source_url": req.get("source_url"),
            "selected_tweet": req.get("selected_tweet"),
            "batch_id": req.get("batch_id"),
            "requested_together": req.get("requested_together") or [req.get("name")],
            "captured_with": req.get("captured_with") or [],
            "auto_queued": bool(req.get("auto_queued")),
            "anticipated": bool(req.get("anticipated")),
            "anticipated_at": req.get("anticipated_at"),
            "anticipated_best_rank": req.get("anticipated_best_rank"),
            "anticipated_social_source_count": int(req.get("anticipated_social_source_count") or 0),
            "anticipated_news_source_count": int(req.get("anticipated_news_source_count") or 0),
            "anticipated_news_title": req.get("anticipated_news_title") or "",
            "anticipated_entered_top10_at": req.get("anticipated_entered_top10_at"),
        })
    # Evita starvation: trabajo nuevo/revisiones primero; problematic al final.
    active.sort(key=lambda x: (
        1 if str(x.get("status") or "") == "problematic" else 0,
        str(x.get("requested_at") or ""),
    ))
    save("editorial-queue.json", {
        "project": "TTendencias",
        "updated_at": datetime.now(MADRID).isoformat(timespec="seconds"),
        "count": len(active),
        "items": active,
    })

recent = load("recent.json", {"items": []})
requests_doc = load("requests.json", {"requests": []})
explained_doc = load("telegram-manual-explained.json", {"items": []})
prepared_doc = load("prepared.json", {"items": []})

requests = requests_doc.setdefault("requests", [])
now_dt = datetime.now(MADRID)
reconciled = False

def canonicalize_explained_groups():
    """Mantiene una sola tarjeta visible por grupo editorial.

    Si una carrera o una pasada editorial añade miembros del mismo group_id
    como explained independientes, conserva el líder y marca el resto grouped.
    """
    groups = {}
    for entry in explained_doc.get("items", []) or []:
        if str(entry.get("status") or "") != "explained":
            continue
        group = str(entry.get("explanation_group_id") or entry.get("group_id") or "").strip()
        if group:
            groups.setdefault(group, []).append(entry)
    changed = 0
    for group, entries in groups.items():
        if len(entries) < 2:
            continue
        leader_id = ""
        for entry in entries:
            candidate = str(entry.get("group_leader_id") or "").strip()
            if candidate:
                leader_id = candidate
                break
        leader = next((x for x in entries if str(x.get("id") or "") == leader_id), None)
        if leader is None:
            leader = min(entries, key=lambda x: str(x.get("explained_at") or "9999"))
            leader_id = str(leader.get("id") or "")
        for entry in entries:
            if entry is leader:
                entry["status"] = "explained"
                continue
            entry["status"] = "grouped"
            entry["group_leader_id"] = leader_id
            entry["grouped_into"] = leader_id
            entry["grouped_at"] = now_dt.isoformat(timespec="seconds")
            changed += 1
    if changed:
        explained_doc["updated_at"] = now_dt.isoformat(timespec="seconds")
    return changed

canonicalized_groups = canonicalize_explained_groups()

def _copy_if_present(dst, src, field):
    if field in src:
        dst[field] = src[field]

def reconcile_persisted_explanations():
    """Cierra de forma idempotente solicitudes cuya explicación ya existe.

    La clave es SIEMPRE (id, revision). Así una explicación antigua nunca puede
    cerrar por accidente una revisión nueva de la misma tendencia.
    Los grupos usan grouped_member_revisions para cubrir a todos sus miembros.
    """
    coverage = {}
    for entry in explained_doc.get("items", []) or []:
        if str(entry.get("status") or "") != "explained":
            continue
        if not str(entry.get("explanation") or "").strip() or not entry.get("explained_at"):
            continue
        members = []
        if entry.get("id"):
            members.append({
                "id": str(entry.get("id")),
                "revision": int(entry.get("revision") or 0),
            })
        for member in entry.get("grouped_member_revisions") or []:
            if isinstance(member, dict) and member.get("id"):
                members.append({
                    "id": str(member.get("id")),
                    "revision": int(member.get("revision") or 0),
                })
        for member in members:
            key = (member["id"], member["revision"])
            previous = coverage.get(key)
            current_ts = parse_timestamp(entry.get("explained_at"))
            previous_ts = parse_timestamp((previous or {}).get("explained_at"))
            if previous is None or (current_ts and (previous_ts is None or current_ts > previous_ts)):
                coverage[key] = entry

    repaired = 0
    for req in requests:
        key = (str(req.get("id") or ""), int(req.get("revision") or 0))
        entry = coverage.get(key)
        if not entry:
            continue
        status = str(req.get("status") or "")
        if status == "explained":
            continue
        # No revivir ni sobreescribir una decisión explícita del usuario.
        if status == "dismissed":
            continue
        if status not in {"preparing", "update", "problematic", "ready"}:
            continue

        req["status"] = "explained"
        req["explained_at"] = entry.get("explained_at")
        req["explanation"] = entry.get("explanation")
        req["closer_text"] = entry.get("closer_text") or ""
        req["trend_names"] = entry.get("trend_names") or [req.get("name")]
        req["rank_at_explanation"] = entry.get("rank_at_explanation") or entry.get("rank") or req.get("rank")
        req["group_leader_id"] = entry.get("group_leader_id") or entry.get("id") or req.get("id")
        req["news_disposition"] = entry.get("news_disposition") or req.get("news_disposition") or "ignored"
        req["source"] = entry.get("source") or req.get("source") or "editorial_reconciled"
        req["with_image"] = True
        for field in (
            "group_id", "explanation_group_id", "group_title", "trend_context",
            "verification_sources", "ttittulares_event_id", "duplicate_of",
        ):
            _copy_if_present(req, entry, field)
        repaired += 1
        print("Reconciliada explicación persistida:", req.get("name"), "r"+str(req.get("revision") or 0))

    return repaired

repaired_explanations = reconcile_persisted_explanations()
if repaired_explanations:
    reconciled = True
    requests_doc["updated_at"] = now_dt.isoformat(timespec="seconds")
if canonicalized_groups:
    save("telegram-manual-explained.json", explained_doc)
    print("Grupos duplicados consolidados:", canonicalized_groups)

explained = set()
latest_explanation = {}

def remember_explanation(value, explained_at):
    key = norm(value)
    if not key:
        return
    explained.add(key)
    timestamp = parse_timestamp(explained_at)
    if timestamp and (key not in latest_explanation or timestamp > latest_explanation[key]):
        latest_explanation[key] = timestamp

for entry in explained_doc.get("items", []) or []:
    values = []
    if entry.get("name"):
        values.append(entry.get("name"))
    values.extend(entry.get("trend_names") or [])
    for ctx in entry.get("trend_context") or []:
        if isinstance(ctx, dict) and ctx.get("name"):
            values.append(ctx.get("name"))
    for value in values:
        if value:
            remember_explanation(value, entry.get("explained_at"))
prepared_names = set()
prepared_ids = set()
for prepared in prepared_doc.get("items", []) or []:
    if prepared.get("id"):
        prepared_ids.add(str(prepared.get("id")))
    for value in ((prepared.get("related_trends") or []) or [prepared.get("trend_name")]):
        if value:
            prepared_names.add(norm(value))
by_name = {}
for req in requests:
    key = norm(req.get("name"))
    if key:
        by_name[key] = req
        if str(req.get("status") or "") == "explained":
            values = [req.get("name")] + list(req.get("trend_names") or [])
            for value in values:
                remember_explanation(value, req.get("explained_at"))

def capture_is_safe(doc):
    """Evita encolar/reabrir tendencias desde snapshots sin respaldo actual."""
    method = str(doc.get("selection_method") or "")
    sources_used = list(doc.get("sources_used") or [])
    source_data = doc.get("sources") or {}

    if method in {"hold-last-good", "stale-fallback", "none"}:
        return False
    if method in {"fresh-anchor", "aging-anchor"}:
        primary = str(doc.get("primary_source") or "")
        freshness = str((source_data.get(primary) or {}).get("freshness") or "")
        return freshness in {"fresh", "aging"}
    if method == "consensus":
        return len(sources_used) >= 2
    if method == "fallback":
        primary = str(doc.get("primary_source") or "")
        freshness = str((source_data.get(primary) or {}).get("freshness") or "")
        return freshness in {"fresh", "aging"}
    return False

if not capture_is_safe(recent):
    if reconciled:
        requests_doc["updated_at"] = now_dt.isoformat(timespec="seconds")
        save("requests.json", requests_doc)
    save_editorial_queue(requests_doc)
    print(
        "Snapshot TTendencias no fiable para encolar:",
        recent.get("selection_method"),
        recent.get("primary_source"),
        recent.get("sources_used"),
    )
    raise SystemExit(0)

current = []
for item in (recent.get("items") or [])[:10]:
    name = str(item.get("name") or "").strip()
    if name:
        current.append({"name": name, "rank": int(item.get("rank") or 0)})

def explanation_expired(key):
    """Solo reabre una tendencia con una explicación fechada de hace >48 h.

    Si falta o no se puede interpretar la fecha, se conserva la deduplicación
    anterior: una fecha desconocida no debe provocar reexplicaciones masivas.
    """
    explained_at = latest_explanation.get(key)
    return bool(explained_at and now_dt - explained_at > EXPLANATION_TTL)

to_queue = []
for item in current:
    key = norm(item["name"])
    req = by_name.get(key)
    status = str((req or {}).get("status") or "")
    if req:
        if status == "explained" and explanation_expired(key):
            reopened_at = now_dt.isoformat(timespec="seconds")
            req["rank"] = item["rank"]
            req["status"] = "preparing"
            req["requested_at"] = reopened_at
            req["revision"] = int(req.get("revision") or 0) + 1
            req["reexplain"] = True
            req["with_image"] = True
            req["requested_together"] = [item["name"]]
            req["captured_with"] = [x["name"] for x in current]
            req.pop("explained_at", None)
            reconciled = True
            print("Reabierta explicación con más de 48 h:", item["name"])
            continue
        # Una solicitud ready sin tarjeta prepared es un estado imposible:
        # normalmente indica una carrera o borrado parcial. Se reabre de forma
        # idempotente para que el siguiente pase editorial la reconstruya.
        if status == "ready":
            represented = str(req.get("id") or "") in prepared_ids or key in prepared_names
            if represented:
                if bool(req.get("anticipated")):
                    now_entered = datetime.now(MADRID).isoformat(timespec="seconds")
                    req["rank"] = item["rank"]
                    req["status"] = "update"
                    req["requested_at"] = now_entered
                    req["revision"] = int(req.get("revision") or 0) + 1
                    req["reexplain"] = True
                    req["with_image"] = True
                    req["anticipated_entered_top10_at"] = req.get("anticipated_entered_top10_at") or now_entered
                    req["rewrite_instruction"] = "Ha entrado en el Top 10: actualiza el encabezado al puesto real y verifica que el motivo siga siendo actual. Reutiliza la preparación del Radar si sigue siendo válida."
                    req.pop("ready_at", None)
                    req.pop("delivery_confirmation", None)
                    reconciled = True
                    status = "update"
                    print("Radar anticipado entra en Top 10; actualizar:", name)
                    continue
                continue
            req["status"] = "preparing"
            req["requested_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
            reconciled = True
            req.pop("ready_at", None)
            req.pop("delivery_confirmation", None)
            status = "preparing"
            print("Reabierta ready sin prepared:", name)
            continue
        # Cualquier otra decisión/estado vigente se conserva. Las problemáticas
        # no se convierten a preparing: permanecen como problemáticas, pero
        # save_editorial_queue las vuelve a exponer mientras sigan en el Top 10
        # para que la siguiente ejecución editorial haga un nuevo intento.
        if status in {"preparing", "update"} and bool(req.get("anticipated")):
            now_entered = datetime.now(MADRID).isoformat(timespec="seconds")
            if int(req.get("rank") or 0) != item["rank"] or not req.get("anticipated_entered_top10_at"):
                req["rank"] = item["rank"]
                req["anticipated_entered_top10_at"] = req.get("anticipated_entered_top10_at") or now_entered
                reconciled = True
            continue
        if status == "problematic":
            if int(req.get("rank") or 0) != item["rank"]:
                req["rank"] = item["rank"]
                reconciled = True
            continue
        if status in {"preparing", "update", "explained", "dismissed"}:
            continue
    elif key in explained and not explanation_expired(key):
        continue
    to_queue.append(item)

if not to_queue:
    if reconciled:
        requests_doc["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        save("requests.json", requests_doc)
        print("Cola reconciliada; no hay tendencias nuevas que encolar")
    else:
        print("Sin tendencias nuevas que encolar")
    save_editorial_queue(requests_doc)
    raise SystemExit(0)

now = now_dt.isoformat(timespec="seconds")
names = [x["name"] for x in to_queue]
batch_id = hashlib.sha256((" | ".join(names) + " | " + now).encode("utf-8")).hexdigest()[:12]

for item in to_queue:
    name = item["name"]
    key = norm(name)
    req = by_name.get(key)
    req_id = str((req or {}).get("id") or hashlib.sha256(name.encode("utf-8")).hexdigest()[:12])
    new_req = {
        "id": req_id,
        "name": name,
        "rank": item["rank"],
        "status": "preparing",
        "requested_at": now,
        "revision": int((req or {}).get("revision") or 0),
        "reexplain": False,
        "with_image": True,
        "alternatives_target": 0,
        "batch_id": batch_id,
        # Auto-queueing at the same capture time is NOT evidence that trends
        # belong to the same story. Keep semantic grouping conservative.
        "requested_together": [name],
        "captured_with": names,
        "auto_queued": True,
    }
    if req is None:
        requests.append(new_req)
        by_name[key] = new_req
    else:
        req.clear()
        req.update(new_req)

requests_doc["updated_at"] = now
save("requests.json", requests_doc)
save_editorial_queue(requests_doc)
print("Encoladas automáticamente:", ", ".join(names))
