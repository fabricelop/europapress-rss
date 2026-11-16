#!/usr/bin/env python3
"""Identify Chrome processes by the exact Windows --user-data-dir argument.

Prefix matching is unsafe: ChromeProfile, ChromeProfileImages and their
-Parallel-01 copies can all be active at once. Only the exact profile owner
may hide or stop a Chrome process. Command lines never enter journal logs.
"""
from __future__ import annotations

import json
import ntpath
import re
import subprocess


PROFILE_ARGUMENT = re.compile(
    r'(?i)(?:^|\s)(?:"--user-data-dir=([^"]+)"'
    r'|--user-data-dir="([^"]+)"'
    r'|--user-data-dir=([^\s"]+))(?=\s|$)'
)


def command_line_profile(command_line):
    """Extract quoted whole-argument, quoted-value or unquoted Chrome paths."""
    if not isinstance(command_line, str):
        return None
    match = PROFILE_ARGUMENT.search(command_line)
    if not match:
        return None
    return ntpath.normcase(ntpath.normpath(next(group for group in match.groups() if group)))


def matching_pids(processes, expected_profile):
    expected = ntpath.normcase(ntpath.normpath(str(expected_profile)))
    return {int(proc["ProcessId"]) for proc in processes
            if (isinstance(proc, dict)
                and type(proc.get("ProcessId")) is int
                and proc["ProcessId"] > 0
                and command_line_profile(proc.get("CommandLine")) == expected)}


def exact_chrome_profile_pids(profile):
    """Windows-only read: fail closed when process enumeration is uncertain."""
    ps = (
        'Get-CimInstance Win32_Process -Filter "Name=\'chrome.exe\'" | '
        'Where-Object { $_.CommandLine -and $_.CommandLine.Contains("--user-data-dir=") } | '
        'Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress'
    )
    run = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, timeout=20,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if run.returncode:
        raise RuntimeError("V2_CHROME_EXACT_PROFILE_PROCESS_INSPECTION_FAILED")
    raw = run.stdout.strip()
    records = json.loads(raw) if raw else []
    if isinstance(records, dict):
        records = [records]
    if not isinstance(records, list):
        raise RuntimeError("V2_CHROME_PROCESS_LIST_INVALID")
    return matching_pids(records, profile)
