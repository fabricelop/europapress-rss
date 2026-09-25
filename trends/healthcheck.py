#!/usr/bin/env python3
import json, os, urllib.request, urllib.error
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = os.environ.get("GITHUB_REPOSITORY", "fabricelop/europapress-rss")
GH_TOKEN = os.environ.get("GITHUB_TOKEN", "")
BOT_TOKEN = os.environ.get("TTENDENCIAS_BOT_TOKEN", "")
SEND_OUTCOME = os.environ.get("SEND_OUTCOME", "").lower()
STATUS = ROOT / "health-status.json"

def load(name, default=None):
    try:
        return json.loads((ROOT / name).read_text(encoding="utf-8"))
    except Exception:
        return default

def noise_name(value):
    v = " ".join(str(value or "").split()).casefold()
    return (
        v.startswith("explore why ")
        or (" is trending " in (" " + v + " ") and "latest viral tweets" in v)
        or "real-time buzz from twitter" in v
    )

def gh(path, method="GET", payload=None):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/{path}",
        method=method,
        data=(json.dumps(payload).encode() if payload is not None else None),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {GH_TOKEN}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ttendencias-healthcheck",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode("utf-8")
            return r.status, json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")

def workflow_state(filename, max_age_minutes, require_active=False):
    code, data = gh(f"actions/workflows/{filename}/runs?per_page=5")
    if code != 200 or not isinstance(data, dict):
        return {"ok": False, "reason": f"GitHub API {code}", "repairable": True}
    runs = data.get("workflow_runs", [])
    if not runs:
        return {"ok": False, "reason": "sin ejecuciones", "repairable": True}
    run = runs[0]
    status = run.get("status")
    conclusion = run.get("conclusion")
    updated = run.get("updated_at") or run.get("created_at")
    age = 99999
    try:
        dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - dt).total_seconds() / 60
    except Exception:
        pass
    active = status in {"pending", "queued", "in_progress"}
    ok = active if require_active else (active or (conclusion == "success" and age <= max_age_minutes))
    return {
        "ok": ok, "status": status, "conclusion": conclusion, "age_minutes": round(age, 1),
        "run_id": run.get("id"), "reason": None if ok else f"{status}/{conclusion}, {age:.1f} min",
        "repairable": True, "require_active": require_active,
    }

def dispatch(filename):
    code, _ = gh(f"actions/workflows/{filename}/dispatches", "POST", {"ref": "main"})
    return code == 204

def send_alert(chat_id, lines):
    if not BOT_TOKEN or not chat_id:
        return False
    payload = {"chat_id": chat_id, "text": "🚨 TTendencias · fallo bloqueante\n" + "\n".join(lines)}
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode()).get("ok", False)
    except Exception:
        return False

previous = load("health-status.json", {}) or {}
recent = load("recent.json")
requests_doc = load("requests.json")
bot_state = load("telegram-bot-state.json")
listener_state = load("telegram-listener-state.json")
prepared_doc = load("prepared.json")
editorial_runtime = load("editorial-runtime.json", {}) or {}
editorial_config = load("editorial-config.json", {}) or {}
control_mode = load("control-mode.json", {}) or {}
mode = str(control_mode.get("mode") or "telegram").strip().lower()
web_mode = mode == "web"

modules = {}
blocking = []
repairs = []

editorial = editorial_config.get("editorial") or {}
alt_target = int(editorial.get("alternatives_target") or 0)
alt_non_blocking = editorial.get("alternatives_block_send") is False
modules["editorial_config"] = {
    "ok": alt_target == 3 and alt_non_blocking,
    "alternatives_target": alt_target,
    "alternatives_block_send": editorial.get("alternatives_block_send"),
}
if not modules["editorial_config"]["ok"]:
    blocking.append("config editorial TTendencias inválida: deben pedirse 3 alternativas sin bloquear el envío")

modules["control_mode"] = {
    "ok": mode in {"telegram", "web"},
    "mode": mode,
    "web_control_enabled": web_mode,
    "telegram_panel_enabled": not web_mode,
}
if mode not in {"telegram", "web"}:
    blocking.append(f"modo de control TTendencias no válido: {mode}")

# Estado JSON y panel.
for name, obj in [
    ("recent_json", recent), ("requests_json", requests_doc),
    ("bot_state_json", bot_state), ("listener_state_json", listener_state),
    ("prepared_json", prepared_doc)
]:
    modules[name] = {"ok": isinstance(obj, dict)}
    if not isinstance(obj, dict):
        blocking.append(f"{name}: JSON inválido o ilegible")

if isinstance(bot_state, dict):
    if not web_mode:
        delivery_ok = bool(bot_state.get("chat_id"))
        modules["telegram_delivery"] = {"ok": delivery_ok}
        if not delivery_ok:
            blocking.append("chat Telegram de entrega no enlazado")

        panel_ok = bool(bot_state.get("chat_id") and bot_state.get("panel_message_id"))
        modules["telegram_panel"] = {"ok": panel_ok}
        if not panel_ok:
            blocking.append("panel Telegram no enlazado")
    else:
        modules["telegram_delivery"] = {"ok": True, "required": False}
        modules["telegram_panel"] = {"ok": True, "required": False}

# Top 10 y fuentes. También exigimos que la captura sea reciente: un JSON
# estructuralmente válido pero antiguo no significa que el refresco funcione.
top_ok = False
if isinstance(recent, dict):
    top = recent.get("top10") or []
    non_stale = int(recent.get("non_stale_source_count") or 0)

    noisy_top = [x for x in top if noise_name(x)]
    captured_age = 99999.0
    try:
        captured = datetime.fromisoformat(str(recent.get("captured_at")).replace("Z", "+00:00"))
        captured_age = (datetime.now(timezone.utc) - captured.astimezone(timezone.utc)).total_seconds() / 60
    except Exception:
        pass
    top_ok = len(top) == 10 and non_stale >= 3 and captured_age <= 20 and not noisy_top
    modules["top10"] = {
        "ok": top_ok,
        "count": len(top),
        "non_stale_sources": non_stale,
        "captured_age_minutes": round(captured_age, 1),
        "noise_count": len(noisy_top),
    }
    if not top_ok:
        if dispatch("ttendencias-refresh.yml"):
            repairs.append("relanzado refresco Top 10")
            modules["top10"]["repair_started"] = True
        else:
            blocking.append(f"Top 10 no fiable o desactualizado: {len(top)} tendencias / {non_stale} fuentes no obsoletas / {captured_age:.1f} min")

# Procesos continuos.
for key, wf, age in [
    ("listener", "ttendencias-listener.yml", 35),
    ("refresh", "ttendencias-refresh.yml", 40),
]:
    if key == "listener" and web_mode:
        modules[key] = {"ok": True, "required": False, "reason": "control web activo"}
        continue
    st = workflow_state(wf, age, require_active=(key == "listener"))
    modules[key] = st
    if not st["ok"]:
        if dispatch(wf):
            repairs.append(f"relanzado {key}")
            st["repair_started"] = True
        else:
            blocking.append(f"{key}: {st.get('reason')}")

# Una ejecución editorial que no pudo enviar es bloqueante.
if SEND_OUTCOME and SEND_OUTCOME != "success":
    modules["telegram_sender"] = {"ok": False, "outcome": SEND_OUTCOME}
    blocking.append(f"envío Telegram terminó en {SEND_OUTCOME}")
else:
    modules["telegram_sender"] = {"ok": True, "outcome": SEND_OUTCOME or "no-aplica"}

# Cola: estados desconocidos sí son anomalía; preparing/ready/explained son válidos.
if isinstance(requests_doc, dict):
    allowed = {"preparing", "ready", "explained", "update", "dismissed", "problematic"}
    bad = [x for x in requests_doc.get("requests", []) if x.get("status") not in allowed]
    noisy = [x for x in requests_doc.get("requests", []) if noise_name(x.get("name"))]
    modules["request_queue"] = {
        "ok": not bad and not noisy,
        "invalid_count": len(bad),
        "noise_count": len(noisy),
    }
    if bad:
        blocking.append(f"cola con {len(bad)} estado(s) inválido(s)")
    if noisy:
        blocking.append(f"cola con {len(noisy)} tendencia(s) espuria(s)")

# Salud editorial real: una cola sintácticamente válida puede estar bloqueada.
# En horario normal, preparing/update no deben superar el umbral configurado.
if isinstance(requests_doc, dict):
    # Detectar READY huérfanos: nunca deben considerarse sanos si no existe
    # una tarjeta prepared que represente el mismo id o nombre relacionado.
    prepared_ids = set()
    prepared_names = set()
    if isinstance(prepared_doc, dict):
        for item in prepared_doc.get("items", []) or []:
            if item.get("id"):
                prepared_ids.add(str(item.get("id")))
            rel = (item.get("related_trends") or []) or [item.get("trend_name")]
            for name in rel:
                if name:
                    prepared_names.add(" ".join(str(name).casefold().split()))
    orphan_ready = []
    for req in requests_doc.get("requests", []) or []:
        if req.get("status") != "ready":
            continue
        key = " ".join(str(req.get("name") or "").casefold().split())
        if str(req.get("id") or "") not in prepared_ids and key not in prepared_names:
            orphan_ready.append({"id": req.get("id"), "name": req.get("name")})
    modules["ready_consistency"] = {
        "ok": not orphan_ready,
        "orphan_count": len(orphan_ready),
        "orphan_items": orphan_ready[:10],
    }
    if orphan_ready:
        blocking.append(f"{len(orphan_ready)} solicitud(es) ready sin tarjeta prepared")

    active = [x for x in requests_doc.get("requests", []) if x.get("status") in {"preparing", "update"}]
    warn_after = int(editorial.get("delay_warning_after_minutes") or editorial.get("daytime_max_wait_minutes") or 30)
    ages = []
    overdue = []
    now_utc = datetime.now(timezone.utc)
    for req in active:
        age = 0.0
        try:
            dt = datetime.fromisoformat(str(req.get("requested_at") or "").replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            age = max(0.0, (now_utc - dt.astimezone(timezone.utc)).total_seconds() / 60)
        except Exception:
            age = float(warn_after + 1)
        ages.append(age)
        if age > warn_after:
            overdue.append({
                "id": req.get("id"),
                "name": req.get("name"),
                "status": req.get("status"),
                "age_minutes": round(age, 1),
            })
    modules["editorial_queue"] = {
        "ok": not overdue,
        "pending_count": len(active),
        "overdue_count": len(overdue),
        "oldest_age_minutes": round(max(ages), 1) if ages else 0,
        "warning_after_minutes": warn_after,
        "overdue_items": overdue[:10],
        "repairable": False,
    }
    if overdue:
        blocking.append(
            f"cola editorial bloqueada: {len(overdue)} pendiente(s) superan {warn_after} min; "
            f"más antigua {max(ages):.1f} min"
        )

    # El runtime no puede declarar success mientras existan solicitudes
    # preparing/update. Eso ocultaba fallos de hand-off (sin outbox/prepared).
    runtime_status = str(editorial_runtime.get("status") or "")
    impossible_success = runtime_status == "success" and bool(active)
    modules["editorial_runtime"] = {
        "ok": not impossible_success and runtime_status != "failure",
        "status": runtime_status or "unknown",
        "queue_complete": editorial_runtime.get("queue_complete"),
        "remaining_active_ids": editorial_runtime.get("remaining_active_ids") or [],
        "contradictory_success": impossible_success,
    }
    if impossible_success:
        blocking.append(
            f"runtime editorial inconsistente: success con {len(active)} solicitud(es) preparing/update"
        )
    elif runtime_status == "failure":
        blocking.append(
            "runtime editorial en failure: " + str(editorial_runtime.get("error") or "sin detalle")
        )

signature = " | ".join(sorted(blocking))
alerted = False
# En modo web Telegram está fuera del flujo activo de TTendencias. El
# healthcheck conserva diagnóstico y autorreparación, pero no envía avisos.
if blocking and signature != previous.get("last_alert_signature") and not web_mode:
    alerted = send_alert((bot_state or {}).get("chat_id"), blocking)

status = {
    "checked_at": datetime.now(timezone.utc).isoformat(),
    "ok": not blocking,
    "modules": modules,
    "repairs_started": repairs,
    "blocking": blocking,
    "alert_sent": alerted,
    "last_alert_signature": signature if blocking else "",
}
STATUS.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(status, ensure_ascii=False))
