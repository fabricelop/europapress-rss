#!/usr/bin/env python3
import hashlib
import json
import unicodedata
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from reconcile_prepared_ready import reconcile_prepared_ready
from anticipation import sync as sync_anticipation, metrics as anticipation_metrics
from requests_json import dumps_for_path
try:
    from suppression import active_request, purge_pending
except ImportError:
    from trends.suppression import active_request, purge_pending
try:
    # Direct script invocation from the trends directory.
    from trend_episode_policy import treated_terms, editor_initiated, review_episode_token
except ImportError:
    # Also support the package invocation used by some CI callers.
    from trends.trend_episode_policy import treated_terms, editor_initiated, review_episode_token

ROOT = Path(__file__).resolve().parent
MADRID = ZoneInfo("Europe/Madrid")

def load(name, default):
    path = ROOT / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(name, obj):
    (ROOT / name).write_text(dumps_for_path(name, obj), encoding="utf-8")

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
    top30_names = {norm(x.get("name")) for x in (recent_now.get("items") or [])[:30] if x.get("name")}
    active = []
    for req in requests_doc.get("requests", []) or []:
        if active_request(req):
            continue
        status = str(req.get("status") or "")
        if status not in {"preparing", "update", "problematic"}:
            continue
        req_name = norm(req.get("name"))
        # Legacy auto-queued requests from below the Top 30 must not linger
        # in the editorial work queue once they leave the displayed window.
        if status == "problematic" and req_name not in top30_names:
            continue
        # User policy 30/10: every unexplained Top 30 entry is automatic.
        # Keep accepted research when ranks move; exclude only unrelated
        # legacy automatic work that never originated inside the Top 30.
        if (req.get("auto_queued") and int(req.get("rank") or 999) > 30
                and req.get("auto_queue_scope") not in {"top10", "top30"}):
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
            "task": req.get("task") or "explain",
            "anticipation_request": bool(req.get("anticipation_request")),
            "anticipated_name": req.get("anticipated_name"),
            "anticipation_signal": req.get("anticipation_signal"),
            "anticipation_origin_id": req.get("anticipation_origin_id"),
            "anticipation_draft": req.get("anticipation_draft"),
            "red_review_request": req.get("red_review_request"),
            "review_source": req.get("review_source"),
            "review_error": req.get("review_error"),
            # Expose episode-review semantics in the authoritative editorial queue.
            # The editor must know when a repeated label requires a distinct-event
            # check instead of treating it as an ordinary fresh explanation.
            "new_episode_review": bool(req.get("new_episode_review")),
            "distinct_event_required": bool(req.get("distinct_event_required")),
            "radar_episode_token": req.get("radar_episode_token") or "",
            "editor_approval_batch_id": req.get("editor_approval_batch_id") or "",
            "previous_episode_id": req.get("previous_episode_id") or "",
            "review_instruction": req.get("review_instruction") or "",
            "automatic_grouping": req.get("automatic_grouping"),
            "published_context": req.get("published_context"),
            "listas_grouping_request": bool(req.get("listas_grouping_request")),
            "grouping_candidates": req.get("grouping_candidates") or [],
            "grouping_state": req.get("grouping_state"),
            "grouping_error": req.get("grouping_error"),
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
    # Preserve all accepted automatic and manual research.
    # Evita starvation: trabajo nuevo/revisiones primero; problematic al final.
    active.sort(key=lambda x: (
        1 if str(x.get("status") or "") == "problematic" else 0,
        2 if x.get("red_review_request") else 1 if x.get("anticipation_request") else 0,
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
reconciled = purge_pending(requests) > 0
if reconciled:
    print("Solicitudes de tendencias expresamente suprimidas retiradas de la cola.")

# Terminal editor decisions are authoritative for the exact (id, revision).
# Legacy ledgers without a revision still use timestamps so an old occurrence
# cannot close a genuinely newer radar episode that only reused an ID.
CLOSED = {"published", "dismissed", "deleted", "removed",
          "delete_pending", "delete_failed"}
deliveries = load("telegram-image-deliveries.json", {"items": []})
mobile_decisions = load("mobile-decisions.json", {"items": []})
closed_by_id = {}
closed_by_revision = {}
recently_closed_names = set()
recently_closed_topics = {}

def remember_closed_id(item_id, outcome, when, revision=None):
    item_id = str(item_id or "")
    if not item_id or outcome not in CLOSED:
        return
    if revision is not None:
        exact_key = (item_id, int(revision))
        exact_current = closed_by_revision.get(exact_key)
        exact_when = exact_current[1] if exact_current else None
        if exact_current is None or (when and (exact_when is None or when > exact_when)):
            closed_by_revision[exact_key] = (outcome, when, int(revision))
    current = closed_by_id.get(item_id)
    if current is None:
        closed_by_id[item_id] = (outcome, when, revision)
        return
    current_when = current[1]
    if when and (current_when is None or when > current_when):
        closed_by_id[item_id] = (outcome, when, revision)

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
    when = parse_timestamp(event.get("deleted_at") or event.get("published_at")
                           or event.get("dismissed_at") or event.get("delivered_at")
                           or event.get("updated_at"))
    event_id = str(event.get("event_id") or "")
    if event_id:
        revision = event.get("revision")
        revision = int(revision) if revision is not None else None
        remember_closed_id(event_id, outcome, when, revision)
    if when and timedelta(0) <= now_dt - when < timedelta(days=7):
        for name in (event.get("name"), event.get("title")):
            key = norm(name)
            if key:
                recently_closed_names.add(key)
            remember_closed_topic(name, when, outcome)
for decision in (mobile_decisions.get("items") or []):
    outcome = str(decision.get("status") or "").lower()
    if outcome in CLOSED and decision.get("id"):
        when = parse_timestamp(decision.get("deleted_at") or decision.get("published_at")
                               or decision.get("dismissed_at") or decision.get("updated_at"))
        revision = decision.get("revision")
        revision = int(revision) if revision is not None else None
        remember_closed_id(str(decision["id"]), outcome, when, revision)
for request in requests:
    request_id = str(request.get("id") or "")
    request_revision = int(request.get("revision") or 0)
    exact_closed = closed_by_revision.get((request_id, request_revision))
    closed = exact_closed or closed_by_id.get(request_id)
    if not closed or str(request.get("status") or "").lower() in CLOSED:
        continue
    outcome, decision_when, decision_revision = closed
    requested_at = parse_timestamp(request.get("requested_at"))
    # An explicit decision for this exact revision is terminal even if a later
    # radar refresh recreates the deterministic request with a newer timestamp.
    # Timestamp protection remains only for legacy decisions lacking revision.
    if exact_closed is None:
        # Revision ordering is authoritative for the same deterministic ID:
        # a terminal decision from a NEWER revision supersedes any stale
        # older request that a delayed radar/queue writer may have revived.
        if decision_revision is not None:
            if decision_revision < request_revision:
                continue
        elif requested_at and (decision_when is None or decision_when < requested_at):
            continue
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
            and not request.get("new_episode_review")
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

# Legacy grouping is retired. Retain historical groups in their ledger
# records but never create fresh grouped followers or shared Listas cards.
canonicalized_groups = 0


def strip_live_singleton_group_metadata():
    """Normalize current independent cards; do not rewrite old joint groups.

    Some older editorial writers still emit a synthetic grp-<own_id> even
    when there is only ONE trend. That is not a true group and must not leak
    an 'AGRUPADA' label. Keep historical multi-member groups untouched.
    """
    changed_requests = 0
    changed_explanations = 0
    oldest = now_dt - timedelta(hours=48)
    def clean(row):
        if str(row.get("status") or "") != "explained":
            return False
        when = parse_timestamp(row.get("explained_at"))
        if not when or not oldest <= when <= now_dt + timedelta(hours=1):
            return False
        ident = str(row.get("id") or "")
        if not ident or str(row.get("group_leader_id") or "") != ident:
            return False
        names = row.get("trend_names") or [row.get("name")]
        if len(names) != 1 or norm(names[0]) != norm(row.get("name")):
            return False
        members = row.get("grouped_member_revisions") or []
        if any(str(m.get("id") or "") != ident for m in members if isinstance(m,dict)):
            return False
        fields = ("group_id", "explanation_group_id", "group_leader_id",
                  "grouped_into", "grouped_at", "group_title",
                  "grouped_member_revisions", "automatic_grouping",
                  "grouping_candidates", "grouping_state")
        present = any(field in row for field in fields)
        for field in fields:
            row.pop(field, None)
        return present
    for row in requests:
        changed_requests += bool(clean(row))
    for row in explained_doc.get("items") or []:
        changed_explanations += bool(clean(row))
    if changed_explanations:
        explained_doc["updated_at"] = now_dt.isoformat(timespec="seconds")
        save("telegram-manual-explained.json", explained_doc)
    return changed_requests, changed_explanations


stripped_request_groups, stripped_explanation_groups = strip_live_singleton_group_metadata()
if stripped_request_groups or stripped_explanation_groups:
    reconciled = True
    print("Singletons editoriales sin agrupación:",
          stripped_request_groups, stripped_explanation_groups)

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
        if req.get("anticipation_request"):
            continue
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

# The old prepared.json pipeline already has verified editorial text. Its
# READY entries must become Listas independently of missing AI images/Telegram.
# Ignore terminal/newer revisions; the helper is idempotent.
repaired_ready = reconcile_prepared_ready(
    requests_doc, prepared_doc, explained_doc, now_dt.isoformat(timespec="seconds"))
if repaired_ready:
    reconciled = True
    save("telegram-manual-explained.json", explained_doc)
    print("READY de texto reconciliados en Listas:", repaired_ready)

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
active_explained_names = set()
for req in requests:
    key = norm(req.get("name"))
    if key:
        by_name[key] = req
        if (str(req.get("status") or "") == "explained"
                and str(req.get("explanation") or "").strip()
                and str(req.get("telegram_package_status") or "").lower() not in CLOSED
                and str(req.get("id") or "") not in closed_by_id):
            # A real, current explanation is enough. Do not manufacture a new
            # Listas card solely because the same hashtag returns to Top30.
            active_explained_names.add(key)
        # A published/deleted record can retain a real old explanation even
        # after it leaves Listas. Count its *explained_at*, never its removal.
        if (str(req.get("explanation") or "").strip() and req.get("explained_at")
                and not req.get("red_review_request")):
            values = [req.get("name")] + list(req.get("trend_names") or [])
            for value in values:
                remember_explanation(value, req.get("explained_at"))

def capture_is_safe(doc):
    """Evita encolar/reabrir tendencias desde snapshots sin respaldo actual."""
    method = str(doc.get("selection_method") or "")
    sources_used = list(doc.get("sources_used") or [])
    source_data = doc.get("sources") or {}
    if method == "getdaytrends-spain-now":
        # The editor selected the Spain/Ahora table for the Top 30. Its
        # complete ordinal 1-30 is enough to START fact-checking, not to
        # certify X's own live order or to approve/publish any content.
        # GetDayTrends does not expose a trustworthy upstream timestamp.
        # Require our actual Spain scrape to be recent AND a changing list:
        # an old/held/cross-provider ranking must never trigger new work.
        row = source_data.get("getdaytrends") or {}
        observed_at = parse_timestamp(doc.get("captured_at"))
        fetched_at = parse_timestamp(row.get("fetched_at"))
        now = datetime.now(MADRID)
        if (doc.get("country") != "ES"
                or doc.get("primary_source") != "getdaytrends"
                or doc.get("ranking_source_status") == "held"
                or not row.get("ok")
                or row.get("freshness") in {"stale", "invalid", "error"}
                or not observed_at or not fetched_at):
            return False
        if not (0 <= (now - observed_at).total_seconds() <= 25 * 60
                and 0 <= (now - fetched_at).total_seconds() <= 25 * 60):
            return False
        try:
            unchanged = float(row["list_unchanged_minutes"])
        except (KeyError, TypeError, ValueError):
            return False
        if not 0 <= unchanged <= 90:
            return False
        ranked = row.get("trends") or []
        observed = (doc.get("items") or [])[:30]
        if len(ranked) < 30 or len(observed) < 30:
            return False
        source_positions = {norm(name): i for i, name in enumerate(ranked)}
        positions = []
        for i, item in enumerate(observed, 1):
            key = norm(item.get("name"))
            if int(item.get("rank") or 0) != i or not key or key not in source_positions:
                return False
            positions.append(source_positions[key])
        return len(set(positions)) == 30 and positions == sorted(positions)

    # A fetched HTML snapshot is not an observed X ranking. Production data
    # must include a timestamped, genuinely fresh (<=45m) source before
    # automatically creating or reopening editorial work. Empty synthetic
    # sources remain accepted only by the legacy unit-test fixtures.
    if source_data and not any(
        row.get("ok") and row.get("freshness") == "fresh"
        and row.get("age_minutes") is not None
        and 0 <= float(row["age_minutes"]) <= 45
        for row in source_data.values()
    ):
        return False

    if method in {"hold-last-good", "stale-fallback", "none"}:
        return False
    if method == "continuity-anchor":
        primary = str(doc.get("primary_source") or "")
        row = source_data.get(primary) or {}
        peers = list(row.get("continuity_peers") or [])
        try:
            unchanged = float(row.get("list_unchanged_minutes", 9999))
        except (TypeError, ValueError):
            return False
        return bool(
            row.get("ok") and row.get("continuity_verified")
            and 0 <= unchanged <= 60 and peers
            and any((source_data.get(p) or {}).get("ok")
                    and (source_data.get(p) or {}).get("age_minutes") is not None
                    and 0 <= float(source_data[p]["age_minutes"]) <= 150
                    for p in peers)
        )
    if method in {"fresh-anchor", "aging-anchor", "corroborated-anchor"}:
        primary = str(doc.get("primary_source") or "")
        item = source_data.get(primary) or {}
        freshness = str(item.get("freshness") or "")
        if method == "corroborated-anchor":
            # El Top puede ser actual aun cuando el agregador horario de
            # corroboración haya cruzado el límite de 90 minutos. Aceptar
            # hasta 120 minutos SOLO cuando otra lista independiente coincide
            # y la fuente elegida ha cambiado recientemente. Esto habilita
            # INVESTIGACIÓN editorial, no publicación sin verificar los hechos.
            peers = item.get("corroborating_sources") or []
            try:
                last_change_age = float(item.get("list_unchanged_minutes", 9999))
            except (TypeError, ValueError):
                last_change_age = 9999.0
            return (
                freshness == "corroborated-change"
                and last_change_age <= 45
                and any(
                    (source_data.get(peer) or {}).get("ok")
                    and (
                        (source_data.get(peer) or {}).get("freshness") in {"fresh", "aging"}
                        or (
                            (source_data.get(peer) or {}).get("age_minutes") is not None
                            and 0 <= float((source_data.get(peer) or {})["age_minutes"]) <= 120
                        )
                    )
                    for peer in peers
                )
            )
        return freshness in {"fresh", "aging"}
    if method == "consensus":
        return len(sources_used) >= 2
    if method == "fallback":
        primary = str(doc.get("primary_source") or "")
        freshness = str((source_data.get(primary) or {}).get("freshness") or "")
        return freshness in {"fresh", "aging"}
    return False

if not capture_is_safe(recent):
    save("anticipation-metrics.json", anticipation_metrics([x for x in requests if x.get("anticipation_request")]))
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
for item in (recent.get("items") or [])[:30]:
    name = str(item.get("name") or "").strip()
    if active_request({"name": name}):
        continue
    rank = int(item.get("rank") or 0)
    if name and 1 <= rank <= 30:
        current.append({"name": name, "rank": rank})
# User policy 30/10: all pending Top 30 entries enter the same queue.
# Positions outside that window are not selected automatically. Existing
# manual work and investigations already accepted keep their continuity.

# Las problemáticas solo son trabajo vivo mientras sigan en Top 30 o Radar.
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
    req["inactive_reason"] = "left-top30-radar"
    retired_problematic += 1

if retired_problematic:
    reconciled = True
    print("Problemáticas antiguas retiradas:", retired_problematic)

# The >24h return opens *research*, not a new publication. Previously
# published/deleted requests remain authoritative for their exact ID/revision.
# Unverified repeats and within-24h entries still cannot create another ID.
historically_treated = treated_terms(
    requests, explained_doc.get("items") or [],
    deliveries.get("items") or [], mobile_decisions.get("items") or [])
suppressed_reentries = 0
for prior in requests:
    if (prior.get("auto_queued") is True
            and not editor_initiated(prior)
            and norm(prior.get("name")) in historically_treated
            and not prior.get("new_episode_review")
            and str(prior.get("status") or "") in {"preparing", "update", "problematic", "ready"}):
        prior["status"] = "inactive"
        prior["inactive_reason"] = "historical_episode_already_treated"
        prior["inactive_at"] = now_dt.isoformat(timespec="seconds")
        prior["reexplain"] = False
        prior["with_image"] = False
        prior["disable_ai_image"] = True
        suppressed_reentries += 1
        reconciled = True
if suppressed_reentries:
    print("Reentradas automáticas sin novedades bloqueadas:", suppressed_reentries)

# Explicit editor-requested research is one-shot per (batch, literal name).
# Its approval never authorizes publication or restoration of closed episodes.
approved_batches = load("editor-approved-reviews.json", {"batches": []}).get("batches") or []
approved_by_name = {}
snapshot_date = parse_timestamp(recent.get("captured_at"))
for batch in approved_batches:
    if not isinstance(batch, dict) or batch.get("intent") != "research_new_episode":
        continue
    started = parse_timestamp(batch.get("approved_at"))
    expires = parse_timestamp(batch.get("valid_until"))
    snap = parse_timestamp(batch.get("radar_captured_at"))
    batch_id = str(batch.get("id") or "")
    if not batch_id or not started or not expires or not snap or not snapshot_date:
        continue
    if not (started <= now_dt <= expires and snap <= snapshot_date):
        continue
    for term in batch.get("names") or []:
        approved_by_name[norm(term)] = {"id": batch_id, "approved_at": started}

# A review_completed token remains closed for that observed reentry. A NEW,
# separately dated return after >24h can receive a different research token.

to_queue = []
for item in current:
    key = norm(item["name"])
    req = by_name.get(key)
    status = str((req or {}).get("status") or "")
    approval = approved_by_name.get(key) or {}
    approval_id = approval.get("id", "")
    # Another concurrent editorial pass may have ALREADY prepared a fresh
    # independent explanation after this instruction. Never duplicate it.
    completed_after_approval = (approval_id and latest_explanation.get(key)
                                and latest_explanation[key] >= approval["approved_at"])
    if completed_after_approval:
        approval_id = ""
    if approval_id and any(
        norm(old.get("name")) == key and old.get("editor_approval_batch_id") == approval_id
        for old in requests
    ):
        approval_id = ""  # The approved review was already created.
    radar_item = next((
        row for row in (recent.get("items") or [])[:30]
        if norm(row.get("name")) == key), item)
    # An OBSERVED Top30 return more than 24 h after the last explanation
    # deserves investigation. Rank movement/age alone never do. Approval
    # remains an independent explicit route and overrides automatic tokens.
    historical = key in historically_treated
    automatic_token = review_episode_token(
        item["name"], radar_item, req, historically_treated,
        now_dt, latest_explanation.get(key))
    episode_token = "editor:" + approval_id if approval_id else (automatic_token or "")
    distinct_review = bool(historical and episode_token)
    if key in active_explained_names and not (
        distinct_review or (req and editor_initiated(req)
                            and status in {"preparing", "update", "problematic"})
    ):
        continue
    if historical and not distinct_review and not editor_initiated(req):
        continue
    # An old explanation protects its old editorial card, not research into
    # a verified return after the 24-hour boundary.
    if (key in explained or key in latest_explanation) and not distinct_review:
        if status not in {"preparing", "update", "problematic", "ready"}:
            continue
    if key in recently_closed_names and not distinct_review:
        continue
    if (editorial_topic(item["name"]) in recently_closed_topics
            and not distinct_review
            and (req is None or req.get("auto_queued") is True)
            and str((req or {}).get("request_source") or "") not in {
                "github_pages_authorized_issue", "telegram_reexplain", "telegram_private_deeplink_native"}):
        continue
    if req:
        # Una solicitud ready sin tarjeta prepared es un estado imposible:
        # normalmente indica una carrera o borrado parcial. Se reabre de forma
        # idempotente para que el siguiente pase editorial la reconstruya.
        if status == "ready":
            represented = str(req.get("id") or "") in prepared_ids or key in prepared_names
            if represented:
                if bool(req.get("anticipated")) and item["rank"] <= 10:
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
            print("Reabierta ready sin prepared:", req.get("name"))
            continue
        # Cualquier otra decisión/estado vigente se conserva. Las problemáticas
        # no se convierten a preparing: permanecen como problemáticas, pero
        # save_editorial_queue las vuelve a exponer mientras sigan en el Top 30
        # para que la siguiente ejecución editorial haga un nuevo intento.
        if status in {"preparing", "update"} and bool(req.get("anticipated")) and item["rank"] <= 10:
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
        if status in {"preparing", "update", "problematic", "ready"}:
            continue
        if status in {"explained", "grouped", "dismissed",
                      "published", "removed", "deleted", "review_completed"} and not distinct_review:
            continue
    if episode_token and any(
        norm(old.get("name")) == key and old.get("radar_episode_token") == episode_token
        for old in requests
    ):
        continue
    to_queue.append({**item, "new_episode_review": distinct_review,
                     "radar_episode_token": episode_token or "",
                     "editor_approval_batch_id": approval_id})

def finish_anticipation():
    metrics = sync_anticipation(recent, requests_doc, explained_doc, mobile_decisions, now_dt)
    save("anticipation-metrics.json", metrics)
    requests_doc["updated_at"] = now_dt.isoformat(timespec="seconds")
    save("requests.json", requests_doc)

if not to_queue:
    finish_anticipation()
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
    independent_episode = bool(item.get("radar_episode_token") or
        item.get("new_episode_review") or
        (req and str(req.get("status") or "") == "inactive"))
    episode_token = str(item.get("radar_episode_token") or "")
    req_id = (
        hashlib.sha256(("top30-episode-v2|" + key + "|" +
                        (episode_token or now) + "|" +
                        str((req or {}).get("id") or "")).encode("utf-8")).hexdigest()[:12]
        if independent_episode else
        str((req or {}).get("id") or hashlib.sha256(name.encode("utf-8")).hexdigest()[:12])
    )
    new_req = {
        "id": req_id,
        "name": name,
        "rank": item["rank"],
        "status": "preparing",
        "requested_at": now,
        "revision": 0 if independent_episode else int((req or {}).get("revision") or 0),
        "reexplain": False,
        "with_image": True,
        "alternatives_target": 0,
        "batch_id": batch_id,
        # No new cross-trend group or shared editorial card.
        "requested_together": [name],
        "captured_with": [name],
        "automatic_grouping": False,
        "grouping_disabled": True,
        "auto_queued": True,
        "auto_queue_scope": "top30",
        # A unique ID here is an isolated RESEARCH job, not a new Listas card.
        # Its previous episode and user's publication/deletion remain intact.
        "new_episode_review": bool(item.get("new_episode_review")),
        "recurring_top30_name": bool(item.get("new_episode_review")),
        "radar_episode_token": episode_token,
        "radar_episode_started_at": next((
            x.get("entered_top30_at") for x in (recent.get("items") or [])[:30]
            if norm(x.get("name")) == key), None),
        "editor_approval_batch_id": item.get("editor_approval_batch_id") or "",
        "previous_episode_id": str((req or {}).get("id") or "") if independent_episode else "",
        "distinct_event_required": bool(item.get("new_episode_review")),
        "review_instruction": (
            "Investiga POR QUÉ ha vuelto al Top 30 tras más de 24 h de la "
            "última explicación (o por solicitud expresa). Contrasta hechos "
            "actuales con la ficha anterior. Solo un acontecimiento material, "
            "nuevo e independiente permite otra ficha en Listas. Si sigue el "
            "mismo motivo, conservar la explicación previa y cerrar como "
            "review_completed/no_distinct_event, sin publicación ni imagen. "
            "Un cambio de puesto o seguir en el ranking NO es un retorno."
            if item.get("new_episode_review") else ""
        ),
    }
    if req is None or independent_episode:
        # Keep historical episodes, their decisions and image jobs untouched.
        requests.append(new_req)
        by_name[key] = new_req
    else:
        req.clear()
        req.update(new_req)

requests_doc["updated_at"] = now
save("requests.json", requests_doc)
finish_anticipation()
save_editorial_queue(requests_doc)
print("Encoladas automáticamente:", ", ".join(names))

