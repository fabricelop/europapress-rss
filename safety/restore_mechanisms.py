#!/usr/bin/env python3
"""Restore only TTiTTulares/TTendencias mechanisms from a known-good ref.

Safety properties:
- dry-run by default;
- never resets a branch;
- never deletes files;
- exclusion rules win over inclusion rules;
- live state/history/images are intentionally excluded.

Run from a clean git clone:
  python safety/restore_mechanisms.py
  python safety/restore_mechanisms.py --apply
  python safety/restore_mechanisms.py --apply --path trends/telegram_bot.py
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "safety" / "mechanism-backup-policy.json"


def run_git(*args: str, binary: bool = False):
    proc = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=not binary,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace") if binary else proc.stderr
        raise RuntimeError(f"git {' '.join(args)} failed: {err.strip()}")
    return proc.stdout


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def load_policy() -> dict:
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def mechanism_paths(source_ref: str, policy: dict) -> list[str]:
    names = run_git("ls-tree", "-r", "--name-only", source_ref).splitlines()
    include = policy["rules"]["include"]
    exclude = policy["rules"]["exclude"]
    selected = []
    for path in names:
        if not matches(path, include):
            continue
        if matches(path, exclude):
            continue
        selected.append(path)
    return sorted(set(selected))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-ref", help="Known-good ref to restore from")
    parser.add_argument("--apply", action="store_true", help="Actually write files")
    parser.add_argument(
        "--path",
        action="append",
        default=[],
        help="Limit to an exact mechanism path; may be repeated",
    )
    args = parser.parse_args()

    policy = load_policy()
    source_ref = args.source_ref or policy["backup_ref"]
    allowed = mechanism_paths(source_ref, policy)

    requested = set(args.path)
    if requested:
        unknown = sorted(requested - set(allowed))
        if unknown:
            print("REFUSED: requested path is not in the mechanism allow-list:")
            for path in unknown:
                print(f"  - {path}")
            return 2
        selected = [p for p in allowed if p in requested]
    else:
        selected = allowed

    mode = "APPLY" if args.apply else "DRY-RUN"
    print(f"{mode}: source={source_ref} mechanism_files={len(selected)}")
    for path in selected:
        print(path)

    if not args.apply:
        print("\nNo files changed. Re-run with --apply to restore these mechanisms.")
        return 0

    for path in selected:
        blob = run_git("show", f"{source_ref}:{path}", binary=True)
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)

    print(
        "\nMechanism files restored in the working tree only. "
        "No git reset, no deletion, no state/history restoration."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
