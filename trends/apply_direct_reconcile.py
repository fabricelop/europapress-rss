#!/usr/bin/env python3
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
TRENDS = ROOT / "trends"
MADRID = ZoneInfo("Europe/Madrid")
CMD = TRENDS / "direct-reconcile-command.json"
ACTIVE = {"preparing", "update", "problematic"}


def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def request_for(requests, item_id, revision):
    return next(
        (
            x
            for x in requests.get("requests", [])
            if str(x.get("id") or "") == item_id
            and int(x.get("revision") or 0) == revision
        ),
        None,
    )


def validate_text(group):
    explanation = str(group.get("explanation") or "").strip()
    closer = str(group.get("closer_text") or "").strip()
    if not explanation:
        raise SystemExit("Explicación vacía")
    if len(explanation) >= 280:
        raise SystemExit(f"Explicación >=280 caracteres ({len(explanation)})")
    if not explanation.startswith("TT#"):
        raise SystemExit("Explicación sin prefijo TT#")
    if closer:
        if not closer.startswith("🌶️ "):
            raise SystemExit("closer_text sin prefijo 🌶️")
        if explanation.count(closer) != 1:
            raise SystemExit("closer_text no aparece exactamente una vez en explanation")
    return explanation, closer


def apply_link_existing_group(cmd, explained, requests, queue, now):
    leader_id = str(cmd.get("group_leader_id") or "")
    leader_rev = int(cmd.get("group_leader_revision") or 0)
    group_id = str(cmd.get("group_id") or "")
    leader = next(
        (
            x
            for x in explained.get("items", [])
            if str(x.get("id") or "") == leader_id
            and int(x.get("revision") or 0) == leader_rev
            and str(x.get("group_id") or x.get("explanation_group_id") or "") == group_id
        ),
        None,
    )
    if not leader or str(leader.get("status") or "").lower() != "explained":
        raise SystemExit("Líder explained no encontrado")

    members = cmd.get("members") or []
    pairs = {(str(m.get("id") or ""), int(m.get("revision") or 0)) for m in members}
    if not pairs:
        raise SystemExit("Sin miembros")

    for member in members:
        mid = str(member.get("id") or "")
        rev = int(member.get("revision") or 0)
        req = request_for(requests, mid, rev)
        if req is None:
            raise SystemExit(f"Request inexistente {mid}:r{rev}")
        if str(req.get("status") or "") not in {"preparing", "update", "explained"}:
            raise SystemExit(f"Estado no reconciliable {mid}:r{rev}={req.get('status')}")
        req.update(
            {
                "status": "explained",
                "explained_at": leader.get("explained_at") or now,
                "last_attempt_at": now,
                "explanation": leader.get("explanation") or "",
                "closer_text": leader.get("closer_text") or "",
                "category": leader.get("category") or "Deportes",
                "rank_at_explanation": member.get("rank"),
                "source": "editorial_chat_direct_group_link",
                "editorial_engine": "chat-direct",
                "group_id": group_id,
                "explanation_group_id": group_id,
                "group_title": leader.get("group_title") or "",
                "group_leader_id": leader_id,
                "trend_names": leader.get("trend_names") or [],
                "trend_context": leader.get("trend_context") or [],
                "grouped_member_revisions": leader.get("grouped_member_revisions") or [],
                "verification_sources": leader.get("verification_sources") or [],
                "news_disposition": "ignored",
                "news_note": leader.get("news_note") or "",
                "disable_ai_image": False,
                "image_strategy": "ai_plus_fallback",
                "image_pending": False,
                "rewrite_pending": False,
                "material_novelty_verified": False,
                "grouped_into_existing_card": True,
            }
        )

    return pairs


def apply_persist_explained(cmd, explained, requests, queue, now):
    groups = cmd.get("groups") or []
    if not groups:
        raise SystemExit("Sin grupos para persistir")

    planned = []
    all_pairs = set()

    # JIT barrier: validate every exact revision before changing any document.
    for group in groups:
        explanation, closer = validate_text(group)
        leader_id = str(group.get("id") or "")
        leader_rev = int(group.get("revision") or 0)
        name = str(group.get("name") or "").strip()
        group_id = str(group.get("group_id") or "").strip()
        members = group.get("members") or [
            {
                "id": leader_id,
                "revision": leader_rev,
                "name": name,
                "rank": group.get("rank"),
            }
        ]
        if not leader_id or not name or not group_id:
            raise SystemExit("Grupo sin id/name/group_id")

        normalized_members = []
        for member in members:
            mid = str(member.get("id") or "")
            rev = int(member.get("revision") or 0)
            if not mid:
                raise SystemExit("Miembro sin id")
            req = request_for(requests, mid, rev)
            if req is None:
                raise SystemExit(f"Request inexistente {mid}:r{rev}")
            status = str(req.get("status") or "")
            if status == "explained":
                if str(req.get("explanation") or "") != explanation:
                    raise SystemExit(f"Revisión ya explicada con otro texto {mid}:r{rev}")
            elif status not in ACTIVE:
                raise SystemExit(f"Estado no persistible {mid}:r{rev}={status}")

            pair = (mid, rev)
            if pair in all_pairs:
                raise SystemExit(f"Miembro duplicado {mid}:r{rev}")
            all_pairs.add(pair)
            normalized_members.append(
                {
                    "id": mid,
                    "revision": rev,
                    "name": str(member.get("name") or req.get("name") or mid),
                    "rank": member.get("rank", req.get("rank")),
                }
            )

        if (leader_id, leader_rev) not in {(m["id"], m["revision"]) for m in normalized_members}:
            raise SystemExit("El líder no figura entre los miembros")

        planned.append(
            {
                "group": group,
                "explanation": explanation,
                "closer": closer,
                "members": normalized_members,
            }
        )

    for plan in planned:
        group = plan["group"]
        explanation = plan["explanation"]
        closer = plan["closer"]
        members = plan["members"]
        leader_id = str(group.get("id"))
        leader_rev = int(group.get("revision") or 0)
        group_id = str(group.get("group_id"))
        group_title = str(group.get("group_title") or group.get("name") or "")
        trend_names = [m["name"] for m in members]
        trend_context = [
            {
                "id": m["id"],
                "name": m["name"],
                "rank": m.get("rank"),
                "revision": m["revision"],
            }
            for m in members
        ]
        grouped_member_revisions = [
            {"id": m["id"], "name": m["name"], "revision": m["revision"]}
            for m in members
        ]
        explained_at = str(group.get("explained_at") or cmd.get("explained_at") or now)
        category = str(group.get("category") or "Otros")
        verification_sources = list(group.get("verification_sources") or [])
        news_note = str(group.get("news_note") or "")

        row = next(
            (
                x
                for x in explained.get("items", [])
                if str(x.get("id") or "") == leader_id
                and int(x.get("revision") or 0) == leader_rev
            ),
            None,
        )
        if row is None:
            row = {}
            explained.setdefault("items", []).append(row)

        row.update(
            {
                "id": leader_id,
                "name": str(group.get("name") or ""),
                "revision": leader_rev,
                "status": "explained",
                "explained_at": explained_at,
                "explanation": explanation,
                "closer_text": closer,
                "rank": group.get("rank"),
                "rank_at_explanation": group.get("rank"),
                "category": category,
                "source": "editorial_chat_direct",
                "editorial_engine": "chat-direct",
                "verification_sources": verification_sources,
                "news_note": news_note,
                "group_id": group_id,
                "explanation_group_id": group_id,
                "group_title": group_title,
                "group_leader_id": leader_id,
                "trend_names": trend_names,
                "trend_context": trend_context,
                "grouped_member_revisions": grouped_member_revisions,
                "with_image": True,
                "disable_ai_image": False,
                "image_strategy": "ai_plus_fallback",
                "image_pending": False,
            }
        )

        for member in members:
            req = request_for(requests, member["id"], member["revision"])
            req.update(
                {
                    "status": "explained",
                    "reexplain": False,
                    "explained_at": explained_at,
                    "last_attempt_at": now,
                    "explanation": explanation,
                    "closer_text": closer,
                    "rank_at_explanation": member.get("rank"),
                    "category": category,
                    "source": "editorial_chat_direct",
                    "editorial_engine": "chat-direct",
                    "verification_sources": verification_sources,
                    "news_disposition": "ignored",
                    "news_note": news_note,
                    "group_id": group_id,
                    "explanation_group_id": group_id,
                    "group_title": group_title,
                    "group_leader_id": leader_id,
                    "trend_names": trend_names,
                    "trend_context": trend_context,
                    "grouped_member_revisions": grouped_member_revisions,
                    "with_image": True,
                    "disable_ai_image": False,
                    "image_strategy": "ai_plus_fallback",
                    "image_pending": False,
                    "rewrite_pending": False,
                    "grouped_into_existing_card": member["id"] != leader_id,
                }
            )
            for field in ("problem_reason", "problematic_at", "closer_missing"):
                req.pop(field, None)

    explained["updated_at"] = now
    return all_pairs


def main():
    if not CMD.exists():
        print("TTENDENCIAS_DIRECT_RECONCILE_NO_COMMAND")
        return 0

    cmd = load(CMD, {})
    if cmd.get("project") != "TTendencias":
        raise SystemExit("Comando directo no válido")

    explained_path = TRENDS / "telegram-manual-explained.json"
    requests_path = TRENDS / "requests.json"
    queue_path = TRENDS / "editorial-queue.json"
    explained = load(explained_path, {"items": []})
    requests = load(requests_path, {"requests": []})
    queue = load(queue_path, {"items": []})
    now = datetime.now(MADRID).isoformat(timespec="seconds")

    action = str(cmd.get("action") or "")
    if action == "link_existing_group":
        pairs = apply_link_existing_group(cmd, explained, requests, queue, now)
    elif action == "persist_explained":
        pairs = apply_persist_explained(cmd, explained, requests, queue, now)
    else:
        raise SystemExit(f"Acción directa no válida: {action}")

    requests["updated_at"] = now
    queue["items"] = [
        x
        for x in (queue.get("items") or [])
        if (str(x.get("id") or ""), int(x.get("revision") or 0)) not in pairs
    ]
    queue["count"] = len(queue["items"])
    queue["updated_at"] = now

    save(explained_path, explained)
    save(requests_path, requests)
    save(queue_path, queue)
    CMD.unlink()

    print(
        "TTENDENCIAS_DIRECT_RECONCILE_DONE",
        action,
        len(pairs),
        queue["count"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
