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

def workflow_state(filename, max_age_minutes):
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
    ok = status in {"queued", "in_progress"} or (conclusion == "success" and age <= max_age_minutes)
    return {
        "ok": ok, "status": status, "conclusion": conclusion, "age_minutes": round(age, 1),
        "run_id": run.get("id"), "reason": None if ok else f"{status}/{conclusion}, {age:.1f} min",
        "repairable": True,
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

modules = {}
blocking = []
repairs = []

# Estado JSON y panel.
for name, obj in [
    ("recent_json", recent), ("requests_json", requests_doc),
    ("bot_state_json", bot_state), ("listener_state_json", listener_state)
]:
    modules[name] = {"ok": isinstance(obj, dict)}
    if not isinstance(obj, dict):
        blocking.append(f"{name}: JSON inválido o ilegible")

if isinstance(bot_state, dict):
    panel_ok = bool(bot_state.get("chat_id") and bot_state.get("panel_message_id"))
    modules["telegram_panel"] = {"ok": panel_ok}
    if not panel_ok:
        blocking.append("panel Telegram no enlazado")

# Top 10 y fuentes.
top_ok = False
if isinstance(recent, dict):
    top = recent.get("top10") or []
    non_stale = int(recent.get("non_stale_source_count") or 0)
    top_ok = len(top) == 10 and non_stale >= 3
    modules["top10"] = {"ok": top_ok, "count": len(top), "non_stale_sources": non_stale}
    if not top_ok:
        if dispatch("ttendencias-refresh.yml"):
            repairs.append("relanzado refresco Top 10")
            modules["top10"]["repair_started"] = True
        else:
            blocking.append(f"Top 10 no fiable: {len(top)} tendencias / {non_stale} fuentes no obsoletas")

# Procesos continuos.
for key, wf, age in [
    ("listener", "ttendencias-listener.yml", 70),
    ("refresh", "ttendencias-refresh.yml", 40),
]:
    st = workflow_state(wf, age)
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
    allowed = {"preparing", "ready", "explained", "update"}
    bad = [x for x in requests_doc.get("requests", []) if x.get("status") not in allowed]
    modules["request_queue"] = {"ok": not bad, "invalid_count": len(bad)}
    if bad:
        blocking.append(f"cola con {len(bad)} estado(s) inválido(s)")

signature = " | ".join(sorted(blocking))
alerted = False
if blocking and signature != previous.get("last_alert_signature"):
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
