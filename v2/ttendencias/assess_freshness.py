#!/usr/bin/env python3
"""Paso 2: diagnóstico de frescura sin confundir HTTP, captura y datos X."""
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from trends.update_trends import term_key


def moment(raw):
    if not raw:
        raise ValueError("Falta fecha de captura verificable")
    value = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError("Fecha sin zona horaria")
    return value.astimezone(timezone.utc)


def evaluate(snapshot, *, now=None, previous=None, max_capture_age_minutes=20):
    """La frescura de la lectura no certifica la frescura original de X.

    No declarar datos frescos por HTTP 200, una fecha de consulta reciente,
    cache miss, cambio de posiciones ni mera coincidencia con otra página.
    """
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("now debe incluir zona horaria")
    if snapshot.get("mode") != "live" or snapshot.get("country") != "ES":
        raise ValueError("Solo se evalúan capturas en vivo de España")
    terms = snapshot.get("top30") or []
    if snapshot.get("count") != 30 or len(terms) != 30 or len({term_key(t) for t in terms}) != 30:
        raise ValueError("Top30 incompleto o inconsistente")
    age = (now.astimezone(timezone.utc) - moment(snapshot.get("observed_at"))).total_seconds() / 60
    if age < -2:
        raise ValueError("La captura tiene una fecha futura anómala")
    current_key = "\n".join(term_key(t) for t in terms)
    digest = hashlib.sha256(current_key.encode("utf-8")).hexdigest()
    status = "capture_recent_source_unverified" if age <= max_capture_age_minutes else "capture_expired"
    previous_check = None
    if previous is not None:
        old_terms = previous.get("top30") or []
        if previous.get("mode") != "live" or previous.get("country") != "ES" or len(old_terms) != 30:
            raise ValueError("Referencia previa no válida")
        delta = (moment(snapshot["observed_at"]) - moment(previous["observed_at"])).total_seconds() / 60
        if delta < 0:
            raise ValueError("La captura previa es más nueva que la actual")
        old_key = "\n".join(term_key(t) for t in old_terms)
        previous_check = {
            "interval_minutes": round(delta, 2),
            "ranking_changed": current_key != old_key,
            "common_terms": len({term_key(x) for x in terms} & {term_key(x) for x in old_terms}),
            "note": "Un ranking sin cambios NO prueba que esté caducado; uno cambiante NO certifica X en vivo.",
        }
    return {
        "schema_version": 1,
        "step": "02_freshness",
        "status": status,
        "capture_age_minutes": round(max(0.0, age), 2),
        "max_capture_age_minutes": max_capture_age_minutes,
        "ranking_sha256": digest,
        "source_observed_at": None,
        "source_age_minutes": None,
        "source_freshness_verified": False,
        "verified_against_x": False,
        "eligible_for_editorial": False,
        "reason": "No existe marca de observación de X verificable de forma independiente",
        "comparison": previous_check,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", help="JSON V2 de la captura real")
    parser.add_argument("--previous", help="Captura anterior V2 opcional")
    args = parser.parse_args()
    item = json.loads(Path(args.snapshot).read_text(encoding="utf-8"))
    prev = json.loads(Path(args.previous).read_text(encoding="utf-8")) if args.previous else None
    print(json.dumps(evaluate(item, previous=prev), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
