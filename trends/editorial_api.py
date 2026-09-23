#!/usr/bin/env python3
"""
TTendencias editorial API failover.

Purpose:
- Recover overdue TTendencias editorial requests if the ChatGPT :10/:40 pass
  did not complete them.
- Run from an already reliable GitHub workflow instead of depending on another
  scheduler.
- Be idempotent: only touches requests still in preparing/update.
- Never mark infrastructure/API failures as problematic.

Activation:
- trends/editorial-config.json -> api_failover.enabled = true
- OPENAI_API_KEY present in the GitHub Actions environment
"""
from __future__ import annotations

import json
import os
import sys
import time
from copy import deepcopy
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

import requests

ROOT = Path(__file__).resolve().parent.parent
REQ_PATH = ROOT / "trends" / "requests.json"
PREP_PATH = ROOT / "trends" / "prepared.json"
RECENT_PATH = ROOT / "trends" / "recent.json"
CONFIG_PATH = ROOT / "trends" / "editorial-config.json"
RUNTIME_PATH = ROOT / "trends" / "editorial-runtime.json"
MADRID = ZoneInfo("Europe/Madrid")
API_URL = "https://api.openai.com/v1/responses"

ACTIVE_STATES = {"preparing", "update"}
CATEGORY_ICONS = {
    "politics": "🔵",
    "sports": "🟢",
    "entertainment": "🟣",
    "society": "🟠",
    "breaking": "🔴",
    "viral": "🟡",
    "economy": "🟤",
    "other": "⚪",
}


def load(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return deepcopy(default)


def save(path: Path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_dt(value: str | None):
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=MADRID)
        return dt.astimezone(MADRID)
    except Exception:
        return None


def next_editorial_slot(after: datetime) -> datetime:
    """First configured editorial slot strictly after a request time."""
    candidates = []
    day = after.date()
    for offset in range(0, 3):
        d = day + timedelta(days=offset)
        # Editorial daytime: 07:10 through 23:40, plus 00:10/00:40.
        hours = [0] + list(range(7, 24))
        for h in hours:
            for m in (10, 40):
                slot = datetime(d.year, d.month, d.day, h, m, tzinfo=MADRID)
                if slot > after:
                    candidates.append(slot)
        if candidates:
            break
    return min(candidates)


def extract_output_text(resp_json):
    pieces = []
    for item in resp_json.get("output", []):
        if item.get("type") != "message":
            continue
        for part in item.get("content", []):
            if part.get("type") == "output_text" and part.get("text"):
                pieces.append(part["text"])
    return "".join(pieces).strip()


def call_openai(prompt: str, model: str, require_search: bool = True):
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        raise RuntimeError("OPENAI_API_KEY ausente")

    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "status": {"type": "string", "enum": ["ready", "problematic"]},
            "problem_reason": {"type": "string"},
            "category": {
                "type": "string",
                "enum": ["politics", "sports", "entertainment", "society", "breaking", "viral", "economy", "other"],
            },
            "explanation": {"type": "string"},
            "primary_text": {"type": "string"},
            "alternatives": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "remate": {"type": "string"},
                        "tweet_text": {"type": "string"},
                    },
                    "required": ["remate", "tweet_text"],
                },
            },
            "search_terms": {"type": "array", "items": {"type": "string"}},
            "source_urls": {"type": "array", "items": {"type": "string"}},
            "image_candidate": {"type": "boolean"},
            "image_concept": {"type": "string"},
        },
        "required": [
            "status", "problem_reason", "category", "explanation", "primary_text",
            "alternatives", "search_terms", "source_urls", "image_candidate", "image_concept"
        ],
    }

    body = {
        "model": model,
        "input": prompt,
        "reasoning": {"effort": "medium"},
        "text": {
            "format": {
                "type": "json_schema",
                "name": "ttendencias_editorial",
                "strict": True,
                "schema": schema,
            }
        },
    }
    if require_search:
        body["tools"] = [{"type": "web_search"}]
        body["tool_choice"] = "required"

    r = requests.post(
        API_URL,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        json=body,
        timeout=180,
    )
    if r.status_code >= 400:
        raise RuntimeError(f"OpenAI API HTTP {r.status_code}: {r.text[:500]}")
    data = r.json()
    text = extract_output_text(data)
    if not text:
        raise RuntimeError("OpenAI API devolvió salida vacía")
    return json.loads(text)


def validate_result(result, trend_name: str, rank: int):
    if result.get("status") == "problematic":
        reason = (result.get("problem_reason") or "").strip()
        if not reason:
            raise ValueError("problematic sin problem_reason")
        return

    category = result.get("category")
    icon = CATEGORY_ICONS.get(category, "⚪")
    prefix = f"{icon} T{rank} · {trend_name}\n"
    tweets = [result.get("primary_text") or ""] + [
        a.get("tweet_text") or "" for a in (result.get("alternatives") or [])
    ]
    alternatives = result.get("alternatives") or []
    if len(alternatives) != 3:
        raise ValueError(f"se requieren exactamente 3 alternativas; recibidas {len(alternatives)}")
    for idx, txt in enumerate(tweets):
        if not txt.startswith(prefix):
            raise ValueError(f"tuit {idx} no empieza por encabezado exacto {prefix!r}")
        if len(txt) > 280:
            raise ValueError(f"tuit {idx} excede 280 caracteres ({len(txt)})")
        if "\n\n🌶️ " not in txt:
            raise ValueError(f"tuit {idx} no contiene remate con guindilla tras dos saltos reales")
        if "\\\\n" in txt:
            raise ValueError(f"tuit {idx} contiene saltos escapados visibles")
    for idx, alt in enumerate(alternatives, start=1):
        remate = alt.get("remate") or ""
        if not remate.startswith("🌶️ "):
            raise ValueError(f"alternativa {idx} no empieza remate por guindilla")
        if alt.get("tweet_text", "").count(remate) != 1:
            raise ValueError(f"alternativa {idx} no contiene exactamente el mismo remate una vez")


def repair_result(result, trend_name: str, rank: int, model: str, issue: str):
    prompt = f"""
Corrige EXCLUSIVAMENTE el formato del siguiente resultado editorial de TTendencias.
No cambies los hechos ni añadas hechos nuevos. No hagas búsqueda web.
Problema detectado: {issue}

Tendencia exacta: {trend_name}
Puesto actual: T{rank}
Resultado a corregir:
{json.dumps(result, ensure_ascii=False)}

Reglas:
- Mantén status, category, explanation, source_urls, image_candidate e image_concept.
- Devuelve un principal y EXACTAMENTE 3 alternativas.
- Todo remate debe empezar EXACTAMENTE por "🌶️ " y aparecer tras DOS saltos de línea REALES.
- alternatives.remate debe ser exactamente "🌶️ " + la frase de humor.
- Cada tuit completo <=280 caracteres.
- El encabezado exacto obligatorio es el icono de la categoría, espacio, T{rank} · {trend_name}, salto de línea.
- En alternativas, remate es SOLO el remate; tweet_text es el tuit completo.
- Política/instituciones: neutralidad factual; no persuasión partidista.
- No humor con víctimas, tragedias, abusos o sufrimiento.
"""
    return call_openai(prompt, model, require_search=False)


def make_prompt(req, trend_name: str, rank: int, current_top10):
    rewrite = (req.get("rewrite_instruction") or req.get("rewrite_request") or "").strip()
    return f"""
Eres el redactor de TTendencias España. Investiga por qué esta tendencia es tendencia AHORA en España y prepara el bloque editorial para la app.

Tendencia exacta: {trend_name}
Puesto actual: T{rank}
Top 10 capturado ahora: {json.dumps(current_top10, ensure_ascii=False)}
Estado solicitado: {req.get("status")}
Revisión: {req.get("revision", 0)}
Instrucción de reescritura del usuario, si existe: {rewrite or "(ninguna)"}

OBLIGATORIO:
- Usa búsqueda web actual y fuentes fiables. No inventes el motivo.
- Si no puedes determinarlo con suficiente fiabilidad tras investigar, status=problematic y explica una causa concreta en problem_reason. Nunca uses problematic por retraso o problemas técnicos.
- Política/instituciones: neutralidad estricta, hechos atribuidos, sin persuasión partidista.
- Deportes: verifica expresamente el estado o resultado actual.
- explanation: explicación factual breve y clara de por qué es tendencia ahora.
- category determina el icono: politics 🔵, sports 🟢, entertainment 🟣, society 🟠, breaking 🔴, viral 🟡, economy 🟤, other ⚪.
- Si status=ready, primary_text y cada alternative.tweet_text deben empezar EXACTAMENTE por el icono elegido + " T{rank} · {trend_name}" + salto de línea.
- Cada tuit completo debe medir <=280 caracteres.
- Devuelve SIEMPRE exactamente 3 alternativas A/B/C además del principal.
- Todo remate humorístico, incluido el principal, debe empezar EXACTAMENTE por "🌶️ ".
- En cada tuit el remate va después de DOS saltos de línea REALES y empieza por "🌶️ ". Nunca escribas los caracteres visibles \\n.
- En alternatives.remate escribe SOLO "🌶️ " + la frase de humor, exactamente igual que aparece en tweet_text.
- Humor: divertido/mordaz cuando el tema lo permita; nunca a costa de víctimas, tragedias, abusos o sufrimiento.
- search_terms: 1-3 búsquedas útiles para X.
- source_urls: URLs de las fuentes fiables principales realmente usadas.
- image_candidate: true solo si una imagen editorial 1:1 aportaría de verdad (persona/escena/gag visualizable y tema apropiado).
- image_concept: si image_candidate=true, describe una idea visual basada en la explicación factual y en la mezcla del tono general de todos los remates, NO en un remate concreto. Si false, cadena vacía.
"""


def x_url(text: str):
    return "https://twitter.com/intent/tweet?text=" + quote(text, safe="")


def upsert_prepared(prepared, req, result, trend_name, rank):
    items = prepared.setdefault("items", [])
    category = result.get("category")
    alts = []
    for i, a in enumerate((result.get("alternatives") or [])[:3], start=1):
        tw = a.get("tweet_text", "")
        alts.append({
            "label": f"Abrir alt. {i} en X",
            "remate": a.get("remate", ""),
            "tweet_text": tw,
            "url": x_url(tw),
        })

    item = {
        "id": req.get("id"),
        "trend_name": trend_name,
        "related_trends": [trend_name],
        "explanation": result.get("explanation", ""),
        "primary": {
            "text": result.get("primary_text", ""),
            "url": x_url(result.get("primary_text", "")),
        },
        "alternatives": alts,
        "search_terms": (result.get("search_terms") or [])[:3],
        "research_sources": result.get("source_urls") or [],
        "generated_at": datetime.now(MADRID).isoformat(timespec="seconds"),
        "revision": req.get("revision", 0),
        "editorial_engine": "openai-api-failover",
        "image_candidate": bool(result.get("image_candidate")),
        "image_status": "pending" if result.get("image_candidate") else "none",
        "image_concept": result.get("image_concept") or "",
        "image_url": None,
        "image_blob_path": None,
        "image_error": None,
    }
    items[:] = [x for x in items if x.get("id") != item["id"]]
    items.append(item)
    prepared["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")


def main():
    cfg = load(CONFIG_PATH, {})
    api_cfg = cfg.get("editorial", {}).get("api_failover", {})
    if not api_cfg.get("enabled", False):
        print("TTendencias API failover desactivado.")
        return 0

    if not os.environ.get("OPENAI_API_KEY", "").strip():
        print("TTendencias API failover configurado pero OPENAI_API_KEY no existe; se omite sin fallo.")
        return 0

    grace = int(api_cfg.get("grace_minutes", 8))
    model = api_cfg.get("model", "gpt-5.6-terra")
    now = datetime.now(MADRID)

    req_doc = load(REQ_PATH, {"requests": []})
    prepared = load(PREP_PATH, {"project": "TTendencias", "items": []})
    recent = load(RECENT_PATH, {"top10": [], "items": []})
    runtime = load(RUNTIME_PATH, {})

    ranks = {x.get("name"): x.get("rank") for x in recent.get("items", [])}
    current_top10 = recent.get("top10") or [x.get("name") for x in recent.get("items", [])]

    overdue = []
    for req in req_doc.get("requests", []):
        if req.get("status") not in ACTIVE_STATES:
            continue
        requested = parse_dt(req.get("requested_at")) or now
        due = next_editorial_slot(requested) + timedelta(minutes=grace)
        if now >= due:
            overdue.append((req, due))

    if not overdue:
        print("TTendencias API failover: no hay solicitudes editoriales vencidas.")
        return 0

    runtime.update({
        "engine": "openai-api-failover",
        "status": "running",
        "last_started_at": now.isoformat(timespec="seconds"),
        "processed_ids": [],
        "remaining_ids": [x[0].get("id") for x in overdue],
        "error": None,
        "updated_at": now.isoformat(timespec="seconds"),
    })
    save(RUNTIME_PATH, runtime)

    processed = []
    errors = []
    for req, due in overdue:
        trend_name = req.get("name") or ""
        rank = ranks.get(trend_name) or req.get("rank") or 0
        print(f"Procesando failover {trend_name!r} (T{rank}), vencido desde {due.isoformat()}")

        try:
            result = call_openai(make_prompt(req, trend_name, rank, current_top10), model, require_search=True)
            try:
                validate_result(result, trend_name, rank)
            except Exception as ve:
                print(f"Validación inicial falló para {trend_name}: {ve}; intentando reparación")
                result = repair_result(result, trend_name, rank, model, str(ve))
                validate_result(result, trend_name, rank)

            if result.get("status") == "problematic":
                req["status"] = "problematic"
                req["problematic_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
                req["problem_reason"] = result.get("problem_reason", "").strip()
            else:
                upsert_prepared(prepared, req, result, trend_name, rank)
                req["status"] = "ready"
                req.pop("problem_reason", None)
                req.pop("problematic_at", None)
                req["ready_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
                req["editorial_engine"] = "openai-api-failover"
            processed.append(req.get("id"))
        except Exception as e:
            # Infrastructure/API/format failures are recoverable: keep active.
            errors.append(f"{req.get('id')}:{type(e).__name__}:{e}")
            print(f"ERROR recuperable en {trend_name}: {e}", file=sys.stderr)

    req_doc["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
    save(PREP_PATH, prepared)
    save(REQ_PATH, req_doc)

    remaining = [
        r.get("id") for r in req_doc.get("requests", [])
        if r.get("status") in ACTIVE_STATES and any(r.get("id") == x[0].get("id") for x in overdue)
    ]
    runtime.update({
        "status": "success" if not remaining else "failure",
        "last_completed_at": datetime.now(MADRID).isoformat(timespec="seconds") if not remaining else runtime.get("last_completed_at"),
        "processed_ids": processed,
        "remaining_ids": remaining,
        "error": "; ".join(errors)[:2000] if errors else (None if not remaining else "Quedan solicitudes vencidas sin completar"),
        "api_failover_enabled": True,
        "updated_at": datetime.now(MADRID).isoformat(timespec="seconds"),
    })
    save(RUNTIME_PATH, runtime)

    if remaining:
        print(f"TTendencias API failover dejó {len(remaining)} solicitudes activas para reintento.")
        # Do not fail the whole parent workflow: next stable cycle retries.
    else:
        print(f"TTendencias API failover completó {len(processed)} solicitudes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
