#!/usr/bin/env python3
"""One-time, lossless formatting mitigation for Site's 12M UTF-16 JSON read limit.

Never delete, summarize, filter, reorder or mutate a request. The full history
remains in trends/requests.json; Git preserves the prior readable formatting.
Run --check for diagnostics, --apply to compact only the JSON whitespace.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "trends" / "requests.json"
SITE_LIMIT = 12_000_000

def unique_object(pairs: list[tuple[str, object]]) -> dict:
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"Duplicate JSON key: {key}")
        out[key] = value
    return out

def parse(text: str) -> dict:
    def bad_constant(value: str):
        raise ValueError(f"Invalid non-JSON constant: {value}")
    doc = json.loads(text, object_pairs_hook=unique_object, parse_constant=bad_constant)
    if not isinstance(doc, dict) or not isinstance(doc.get("requests"), list):
        raise ValueError("Expected the original TTendencias requests object and requests list")
    return doc

def units(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2

def minify(source: str) -> tuple[str, int]:
    doc = parse(source)
    candidate = json.dumps(doc, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n"
    if parse(candidate) != doc:
        raise AssertionError("Semantic round-trip mismatch")
    if units(candidate) > SITE_LIMIT:
        raise ValueError("Compacted JSON still exceeds the Site limit; no changes")
    return candidate, len(doc["requests"])

def selftest() -> None:
    sample = '{"project":"TTendencias","requests":[{"id":"uno","name":"La Palma","explanation":"éxito 🌶️","revision":0},{"id":"dos","name":"Otro","notes":"A\\nB"}],"count":2}'
    compact, count = minify(sample)
    assert count == 2 and parse(compact) == parse(sample)
    assert units(compact) <= units(sample)
    for invalid in ('{"requests":[],"requests":[]}', '{"requests":[NaN]}', '{"requests":{}}'):
        try:
            minify(invalid)
        except (ValueError, TypeError, json.JSONDecodeError):
            pass
        else:
            raise AssertionError("Malformed or ambiguous JSON was accepted")
    print("TT_REQUESTS_COMPACTION_SELFTEST_OK")

def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--apply", action="store_true")
    group.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    original_bytes = SOURCE.read_bytes()
    original = original_bytes.decode("utf-8", errors="strict")
    compact, count = minify(original)
    before = units(original)
    after = units(compact)
    print(f"TT_REQUESTS_ORIGINAL: count={count} bytes={len(original_bytes)} utf16={before}")
    print(f"TT_REQUESTS_COMPACT: count={count} bytes={len(compact.encode('utf-8'))} utf16={after}")
    print(f"TT_REQUESTS_SEMANTIC_EQUAL: True; removed_utf16={before-after}")
    if args.apply and original != compact:
        SOURCE.write_bytes(compact.encode("utf-8"))
        print("TT_REQUESTS_LOSSLESS_WHITESPACE_ONLY_APPLIED")
    elif args.apply:
        print("TT_REQUESTS_ALREADY_COMPACT")
    else:
        print("TT_REQUESTS_READ_ONLY_CHECK")

if __name__ == "__main__":
    main()
