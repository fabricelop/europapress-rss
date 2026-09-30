#!/usr/bin/env python3
import base64
import json
import os
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

BASE = Path(__file__).resolve().parent
REQUESTS = BASE / "requests.json"
OUTPUT = BASE / "assistant-output.json"
STATE = BASE / "assistant-state.json"
MARKER = "SELORECORDAMOS_OUTBOX_V1"
REMINDER_RE = re.compile(
    r"\b(?:le\s+recordamos|se\s+lo\s+recordamos|recuerde|queda\s+recordado|"
    r"le\s+recordamos|recordamos|recordarle|recordarte|se\s+lo\s+recuerda)\b",
    re.IGNORECASE,
)

def load(path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback

def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def request_key(req):
    if req.get("type") == "evaluate":
        return f"evaluate:{req.get('tweet_id')}"
    if req.get("type") == "telegram_instruction":
        return f"telegram_instruction:{req.get('telegram_update_id')}"
    return ""

def madrid_time(value):
    if not value:
        return "fecha/hora no disponible"
    try:
        text = str(value).replace("Z", "+00:00")
        dt = datetime.fromisoformat(text)
        return dt.astimezone(ZoneInfo("Europe/Madrid")).strftime("%d/%m/%Y %H:%M")
    except Exception:
        return "fecha/hora no disponible"

def parse_payload():
    body = os.environ.get("SELORECORDAMOS_COMMENT_BODY", "")
    lines = body.splitlines()
    if not lines or lines[0].strip() != MARKER:
        raise ValueError("Marcador de outbox ausente o inválido")
    encoded = "".join(line.strip() for line in lines[1:] if line.strip())
    if not encoded:
        raise ValueError("Payload base64 vacío")
    raw = base64.b64decode(encoded, validate=True)
    payload = json.loads(raw.decode("utf-8"))
    if payload.get("version") != 1:
        raise ValueError("Versión de payload no soportada")
    outputs = payload.get("outputs")
    if not isinstance(outputs, list) or not outputs or len(outputs) > 20:
        raise ValueError("outputs debe contener entre 1 y 20 elementos")
    return payload

def validate_output(item, req):
    key = request_key(req)
    if item.get("request_key") != key:
        raise ValueError("request_key no coincide con la solicitud")
    if item.get("send_to_telegram") is not True:
        raise ValueError("send_to_telegram debe ser true")
    if str(item.get("original_url") or "") != str(req.get("url") or ""):
        raise ValueError("original_url no coincide")
    if not str(item.get("created_at") or "").strip():
        raise ValueError("created_at ausente")

    telegram_text = str(item.get("telegram_text") or "")
    if not telegram_text.strip():
        raise ValueError("telegram_text ausente")
    if str(req.get("user") or "") not in telegram_text:
        raise ValueError("telegram_text no contiene el usuario")
    if str(req.get("text") or "") not in telegram_text:
        raise ValueError("telegram_text no contiene el texto original")
    expected_time = madrid_time(req.get("datetime"))
    if expected_time not in telegram_text:
        raise ValueError(f"telegram_text no contiene fecha/hora esperada: {expected_time}")

    alts = item.get("alternatives")
    if req.get("type") == "evaluate":
        if not isinstance(alts, list) or len(alts) != 4:
            raise ValueError("evaluate requiere exactamente 4 alternativas")
    elif req.get("type") == "telegram_instruction":
        if alts is None:
            alts = []
            item["alternatives"] = alts
        if not isinstance(alts, list) or len(alts) not in (0, 4):
            raise ValueError("telegram_instruction admite 0 o 4 alternativas")
    else:
        raise ValueError("tipo de solicitud no soportado")

    if len(alts) == 4:
        for i, alt in enumerate(alts):
            if not isinstance(alt, str) or not alt.strip():
                raise ValueError(f"alternativa {i+1} vacía")
            if len(alt) > 256:
                raise ValueError(f"alternativa {i+1} supera 256 caracteres")
            if not REMINDER_RE.search(alt):
                raise ValueError(f"alternativa {i+1} no contiene acción explícita de recuerdo")
            expected = f"{'ABCD'[i]}) {alt}"
            if expected not in telegram_text:
                raise ValueError(f"telegram_text no contiene la alternativa {'ABCD'[i]}")
    return item

def existing_complete(existing, req):
    try:
        validate_output(dict(existing), req)
        return True
    except Exception:
        return False

def main():
    payload = parse_payload()
    requests_doc = load(REQUESTS, {"requests": []})
    output_doc = load(OUTPUT, {"outputs": []})
    state_doc = load(STATE, {"processed": []})
    requests = requests_doc.setdefault("requests", [])
    outputs = output_doc.setdefault("outputs", [])
    processed = state_doc.setdefault("processed", [])

    req_by_key = {request_key(r): r for r in requests if request_key(r)}
    output_index = {}
    for idx, item in enumerate(outputs):
        key = str(item.get("request_key") or "")
        if key and key not in output_index:
            output_index[key] = idx

    applied, repaired, errors = [], [], []
    changed_output = False
    changed_state = False

    for candidate in payload["outputs"]:
        key = str(candidate.get("request_key") or "")
        req = req_by_key.get(key)
        if not req:
            errors.append({"request_key": key, "error": "solicitud inexistente en requests.json"})
            continue
        try:
            candidate = validate_output(dict(candidate), req)
        except Exception as exc:
            errors.append({"request_key": key, "error": str(exc)})
            continue

        idx = output_index.get(key)
        if idx is not None and existing_complete(outputs[idx], req):
            repaired.append(key)
        elif idx is not None:
            outputs[idx] = candidate
            changed_output = True
            applied.append(key)
        else:
            outputs.append(candidate)
            output_index[key] = len(outputs) - 1
            changed_output = True
            applied.append(key)

        # Solo se marca processed después de que exista una salida completa
        # en la representación que se va a persistir.
        final_item = outputs[output_index[key]]
        if not existing_complete(final_item, req):
            errors.append({"request_key": key, "error": "la salida final no supera la validación"})
            continue
        if key not in processed:
            processed.append(key)
            changed_state = True

    if changed_output:
        save(OUTPUT, output_doc)
    if changed_state:
        save(STATE, state_doc)

    summary = {
        "run_id": payload.get("run_id"),
        "applied": applied,
        "repaired": repaired,
        "errors": errors,
        "output_changed": changed_output,
        "state_changed": changed_state,
    }
    print(json.dumps(summary, ensure_ascii=False))

if __name__ == "__main__":
    main()
