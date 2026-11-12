#!/usr/bin/env python3
"""TTActualidad V2 / Paso 1: lectura independiente del Top30 de España.

Solo consulta GetDayTrends. No lee ni escribe los estados de producción de TT.
Por defecto imprime JSON y NO persiste ninguna modificación. --output permite
un snapshot únicamente dentro de v2/ttendencias/state/.
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import requests

from trends.update_trends import parse_getdaytrends, source_page_explicitly_foreign, term_key

SOURCE = "https://getdaytrends.com/es/spain/"
ROOT = Path(__file__).resolve().parents[2]
STATE_DIR = (ROOT / "v2/ttendencias/state").resolve()


def capture(html, observed_at=None):
    if source_page_explicitly_foreign(html):
        raise ValueError("GetDayTrends: página de país diferente a España")
    names = parse_getdaytrends(html)
    if len(names) < 30:
        raise ValueError(f"GetDayTrends: solo {len(names)} posiciones válidas; no publicar Top30 parcial")
    chosen = names[:30]
    if len({term_key(name) for name in chosen}) != 30:
        raise ValueError("GetDayTrends: ranking duplicado o inconsistente")
    return {
        "schema_version": 1,
        "project": "TTActualidad V2",
        "step": "01_capture",
        "country": "ES",
        "source": SOURCE,
        "observed_at": observed_at or datetime.now(timezone.utc).isoformat(),
        "verified_against_x": False,
        "verification": "third_party_unverified",
        "count": 30,
        "top30": chosen,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", help="Ruta de snapshot SOLO bajo v2/ttendencias/state/")
    parser.add_argument("--fixture", help="HTML de prueba local; jamás trata datos de prueba como producción")
    args = parser.parse_args()
    if args.fixture:
        html = Path(args.fixture).read_text(encoding="utf-8")
    else:
        response = requests.get(SOURCE, timeout=30, headers={
            "User-Agent": "Mozilla/5.0",
            "Accept-Language": "es-ES,es;q=0.9",
            "Cache-Control": "no-cache",
        })
        response.raise_for_status()
        html = response.text
    result = capture(html)
    result["mode"] = "fixture" if args.fixture else "live"
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        target = Path(args.output).resolve()
        if target.parent != STATE_DIR or target.suffix != ".json":
            raise ValueError("Solo se permite escribir archivos .json directamente bajo v2/ttendencias/state/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    main()
