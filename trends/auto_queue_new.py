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

def editorial_topic(value):
    """Explicit, narrow synonyms for a previously closed story.

    Never fold generic words or manual "Preparar" requests into a closed
    topic. New genuinely distinct developments remain manually requestable.
    """
    term = norm(value).lstrip("#")
    if term in {"hispanidad", "feliz dia de la hispanidad", "12deoctubre"}:
        return "fiesta_nacional_12_oct"
    return ""


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
    top30_names = {norm(x.get("name")) for x in (recent_now.get("items") or [])[:30] if x.get("name")}
    active = []
    for req in requests_doc.get("requests", []) or []:
        status = str(req.get("status") or "")
        if status not in {"preparing", "update", "problematic"}:
            continue
        req_name = norm(req.get("name"))
        # Legacy auto-queued requests from below the Top 30 must not linger
        # in the editorial work queue once they leave the displayed window.
        if status == "problematic" and req_name not in top30_names:
            continue
        # Only positions 1-10 may be automatically prepared. A position
        # 11-30 MUST come from explicit "Preparar novedad" or reexplanation.
        # Eligibility is checked WHEN the request enters from Top 10.
        # It must not disappear from 'En elaboración' just because the live
        # ranking changes while research or image enrichment is underway.
        # Legacy requests that originated outside Top 10 remain excluded.
        if (req.get("auto_queued") and int(req.get("rank") or 999) > 10
                and req.get("auto_queue_scope") != "top10"):
            continue
        active.append({
            "id": req.get("id"),
            "name": req.get("name"),
            "rank": req.get("rank"),
            "status": req.get("status"),
            "requested_at": req.get("requested_at"),
            "revision": int(req.get("revision") or 0),
            "rewrite_instruction": req.get("rewrite_instruction") or req.get("rewrite_request") or "",
            "reexplain": bool(req.get("reexplain")),
            "rewrite_with_image": bool(req.get("rewrite_with_image", req.get("with_image", True))),
            "with_image": bool(req.get("with_image", True)),
            "disable_ai_image": bool(req.get("disable_ai_image")),
            "image_strategy": req.get("image_strategy"),
            "selected_tweet_image": req.get("selected_tweet_image"),
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
    # A maximum of ONE automatic outside-Top-10 request is kept active.
    # Existing manually requested work is preserved.
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

# Terminal Telegram decisions are authoritative, including across radar IDs.
# They must be reconciled BEFORE stale explained/ready repair can reopen work.
CLOSED = {"published", "dismissed", "deleted", "removed",
          "delete_pending", "delete_failed"}
deliveries = load("telegram-image-deliveries.json", {"items": []})
mobile_decisions = load("mobile-decisions.json", {"items": []})
closed_by_id = {}
recently_closed_names = set()
recently_closed_topics = {}
def remember_closed_topic(value, when, status):
    group = editorial_topic(value)
    if not group or status not in CLOSED or not when:
        return
    if timedelta(0) <= now_dt - when < timedelta(days=7):
        previous = recently_closed_topics.get(group)
        if previous is None or when > previous:
            recently_closed_topics[group] = when

for event in (deliveries.get("items") or []):
    outcome = str(event.get("status") or "").lower()
    if outcome not in CLOSED:
        continue
    event_id = str(event.get("event_id") or "")
    if event_id:
        closed_by_id[event_id] = outcome
    when = parse_timestamp(event.get("deleted_at") or event.get("published_at")
                           or event.get("dismissed_at") or event.get("delivered_at"))
    if when and timedelta(0) <= now_dt - when < timedelta(days=7):
        for name in (event.get("name"), event.get("title")):
            key = norm(name)
            if key:
                recently_closed_names.add(key)
            remember_closed_topic(name, when, outcome)
for decision in (mobile_decisions.get("items") or []):
    outcome = str(decision.get("status") or "").lower()
    if outcome in CLOSED and decision.get("id"):
        closed_by_id[str(decision["id"])] = outcome
for request in requests:
    outcome = closed_by_id.get(str(request.get("id") or ""))
    if outcome and str(request.get("status") or "").lower() not in CLOSED:
        request["status"] = "deleted" if outcome.startswith("delete_") else outcome
        request["telegram_package_status"] = request["status"]
        request["reexplain"] = False
        reconciled = True

# One Telegram-deleted editorial package may have several narrowly known
# radar labels. An automatically reopened synonym is not a new story.
# Manual editor commands are deliberately exempt.
closed_topic_requests = 0
for request in requests:
    state = str(request.get("status") or "").lower()
    if state in CLOSED:
        when = parse_timestamp(request.get("deleted_at") or request.get("updated_at")
                               or request.get("explained_at") or request.get("requested_at"))
        remember_closed_topic(request.get("name"), when, state)
for request in requests:
    state = str(request.get("status") or "").lower()
    group = editorial_topic(request.get("name"))
    if (group in recently_closed_topics and request.get("auto_queued") is True
            and state in {"preparing", "update", "problematic", "ready"}
            and str(request.get("request_source") or "") not in {
              "github_pages_authorized_issue", "telegram_reexplain",
              "telegram_private_deeplink_native"}):
        request["status"] = "inactive"
        request["inactive_reason"] = "same_subject_closed_in_telegram"
        request["inactive_at"] = now_dt.isoformat(timespec="seconds")
        closed_topic_requests += 1
        reconciled = True
if closed_topic_requests:
    print("Temas ya cerrados: retiradas solicitudes automáticas sin publicar duplicados:",
          closed_topic_requests)

# A manual request may be incorrectly marked explained by a prior group
# whose explanation predates the request. A historical editorial result is
# NEVER proof that the newly requested revision was researched or delivered.
restored_manual = 0
for req in requests:
    if (req.get("auto_queued") is not False or
            str(req.get("request_source") or "") not in
            {"github_pages_authorized_issue", "telegram_reexplain",
             "telegram_private_deeplink_native"} or
            str(req.get("status") or "") != "explained"):
        continue
    requested_at = parse_timestamp(req.get("requested_at"))
    explained_at = parse_timestamp(req.get("explained_at"))
    has_delivery = any(
        str(row.get("event_id") or "") == str(req.get("id") or "")
        and int(row.get("revision") or 0) == int(req.get("revision") or 0)
        and row.get("final") is True
        and str(row.get("status") or "").lower() in {"sent", "published"}
        for row in deliveries.get("items", []) or []
    )
    if not requested_at or not explained_at or explained_at >= requested_at or has_delivery:
        continue
    req["status"] = "preparing"
    req["stale_group_explanation_ignored_at"] = now_dt.isoformat(timespec="seconds")
    req["stale_group_explanation_reason"] = "explanation_predates_manual_request"
    for field in ("explained_at", "explanation", "closer_text", "group_id",
                  "explanation_group_id", "group_title", "group_leader_id",
                  "trend_names", "rank_at_explanation", "verification_sources",
                  "trend_context", "news_disposition"):
        req.pop(field, None)
    restored_manual += 1
    reconciled = True
if restored_manual:
    print("Restauradas solicitudes manuales cerradas con explicación antigua:",
          restored_manual)

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
        # Previous grouped explanations do not complete a later revision,
        # even when an old group has been backfilled with that member ID.
        request_started = parse_timestamp(req.get("requested_at"))
        entry_explained = parse_timestamp(entry.get("explained_at"))
        if request_started and entry_explained and entry_explained < request_started:
            continue
        if str(entry.get("telegram_package_status") or "").lower() in CLOSED:
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
    rank = int(item.get("rank") or 0)
    if name and 1 <= rank <= 10:
        current.append({"name": name, "rank": rank})
# Top 30 is a DISPLAY, not an automatic editorial queue.
# Ranks 11-30 enter "preparing" ONLY when explicitly requested by the editor
# using Preparar novedad; rank <=10 is eligible for automatic investigation.
# Retire mistakenly automatic outside-Top-10 work without erasing explanations.
retired_outside = 0
for req in requests:
    if (req.get("auto_queued") is True and
            int(req.get("rank") or 999) > 10 and
            str(req.get("status") or "") in {"preparing", "update", "problematic", "ready"} and
            str(req.get("request_source") or "") not in
              {"telegram_reexplain", "github_pages_authorized_issue", "telegram_private_deeplink"}):
        req["status"] = "inactive"
        req["inactive_at"] = now_dt.isoformat(timespec="seconds")
        req["inactive_reason"] = "top11_30_manual_only"
        req["auto_queue_scope"] = "retired"
        retired_outside += 1
if retired_outside:
    reconciled = True
    print("Fuera de Top 10 automático: retiradas", retired_outside,
          "solicitudes de posiciones 11-30; preparar novedad es manual")

# Las problemáticas solo son trabajo vivo mientras sigan en Top 10 o Radar.
# Si salen de ambos, se retiran a un estado inerte. Si vuelven a aparecer,
# se abrirá una revisión nueva para evitar que un listener atrasado resucite
# la revisión problemática antigua.
current_names = {norm(x["name"]) for x in current}
radar_names = {
    norm(x.get("name"))
    for x in (recent.get("upcoming") or [])
    if x.get("name")
}
retired_problematic = 0
for req in requests:
    if str(req.get("status") or "") != "problematic":
        continue
    key = norm(req.get("name"))
    if not key or key in current_names or key in radar_names:
        continue
    req["status"] = "inactive"
    req["inactive_at"] = now_dt.isoformat(timespec="seconds")
    req["inactive_reason"] = "left-top10-radar"
    retired_problematic += 1

if retired_problematic:
    reconciled = True
    print("Problemáticas antiguas retiradas:", retired_problematic)

def explanation_expired(key):
    """Solo reabre una tendencia con una explicación fechada de hace >48 h.

    Si falta o no se puede interpretar la fecha, se conserva la deduplicación
    anterior: una fecha desconocida no debe provocar reexplicaciones masivas.
    """
    explained_at = latest_explanation.get(key)
    return bool(explained_at and now_dt - explained_at > EXPLANATION_TTL)

def closed_name_eligible_for_new_event(req, item):
    """A deleted old package must not block a genuinely new Top-10 occurrence.

    Re-entry after 48h opens a separate ID; the old deleted revision stays
    terminal. Holiday aliases remain explicitly protected from auto-reopen.
    """
    if editorial_topic(item["name"]):
        return False
    if str((req or {}).get("status") or "").lower() not in CLOSED:
        return False
    latest = parse_timestamp((req or {}).get("deleted_at") or (req or {}).get("published_at")
                             or (req or {}).get("dismissed_at") or (req or {}).get("updated_at")
                             or (req or {}).get("explained_at"))
    last_explanation = latest_explanation.get(norm(item["name"]))
    if latest and timedelta(0) <= now_dt - latest < EXPLANATION_TTL:
        return False
    # A current Top-10 appearance, 48h after both last explanation and close,
    # is evidence of re-entry, not evidence that an older result is still true.
    return bool(last_explanation and now_dt - last_explanation > EXPLANATION_TTL)

to_queue = []
for item in current:
    key = norm(item["name"])
    req = by_name.get(key)
    # A deliberate new manual investigation is separate; routine radar
    # captures may not resurrect a Telegram-closed subject for seven days.
    if key in recently_closed_names and (not closed_name_eligible_for_new_event(req, item)):
        continue
    if (editorial_topic(item["name"]) in recently_closed_topics and
            (req is None or req.get("auto_queued") is True) and
            str((req or {}).get("request_source") or "") not in {
              "github_pages_authorized_issue", "telegram_reexplain",
              "telegram_private_deeplink_native"}):
        continue
    status = str((req or {}).get("status") or "")
    # A genuinely resurfaced Top-10 trend must be researched as a NEW event,
    # never silently reuse the old deleted request or revive its media.
    if status in CLOSED and closed_name_eligible_for_new_event(req, item):
        print("Nuevo episodio Top 10 tras cierre anterior:", item["name"])
        status = "new_event"
    if req:
        if item["rank"] <= 10 and status == "explained" and explanation_expired(key):
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
                    print("Radar anticipado entra en Top 10; actualizar:", item["name"])
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
        if status in {"preparing", "update", "explained", "dismissed",
                      "published", "removed", "deleted"}:
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
    closed_reentry = closed_name_eligible_for_new_event(req, item)
    req_id = (
        hashlib.sha256(("top10-reentry|" + key + "|" + now_dt.date().isoformat()).encode("utf-8")).hexdigest()[:12]
        if closed_reentry else
        str((req or {}).get("id") or hashlib.sha256(name.encode("utf-8")).hexdigest()[:12])
    )
    new_req = {
        "id": req_id,
        "name": name,
        "rank": item["rank"],
        "status": "preparing",
        "requested_at": now,
        "revision": 0 if closed_reentry else int((req or {}).get("revision") or 0) + (1 if req and str(req.get("status") or "") == "inactive" else 0),
        "reexplain": False,
        "with_image": True,
        "alternatives_target": 0,
        "batch_id": batch_id,
        # Auto-queueing at the same capture time is NOT evidence that trends
        # belong to the same story. Keep semantic grouping conservative.
        "requested_together": [name],
        "captured_with": names,
        "auto_queued": True,
        "auto_queue_scope": "top10",
    }
    if req is None or closed_reentry:
        # Keep closed historical IDs, append a separate current occurrence.
        requests.append(new_req)
        by_name[key] = new_req
    else:
        req.clear()
        req.update(new_req)

requests_doc["updated_at"] = now
save("requests.json", requests_doc)
save_editorial_queue(requests_doc)
print("Encoladas automáticamente:", ", ".join(names))
