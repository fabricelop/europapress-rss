#!/usr/bin/env python3
"""Verify Chrome CDP readiness on Windows, tolerating a short-lived launcher.

Windows Chrome versions can hand the browser to another process and let the
original chrome.exe exit. Only a real CDP response and the V2-scoped PID
inventory establish browser readiness; exit code of launcher is not enough.
No messages sent, no process cleanup, no V1 references or writes.
"""


class ChromeStartupError(RuntimeError):
    pass


def wait_for_cdp(proc, probe_cdp, profile_pids, *, attempts=40,
                 delay=lambda _: None, absent_limit=5):
    if attempts < 1 or absent_limit < 1:
        raise ValueError("Invalid Chrome readiness limits")
    child_seen = False
    launcher_exited = False
    absent = 0
    last_code = None
    for step in range(attempts):
        # Probe FIRST: a launcher can exit after successfully starting CDP.
        if probe_cdp():
            return {"ready": True, "attempts": step + 1,
                    "launcher_exited": launcher_exited or proc.poll() is not None,
                    "launcher_code": proc.poll(), "children_seen": child_seen}
        code = proc.poll()
        if code is not None:
            launcher_exited = True
            last_code = code
            children = profile_pids()
            if children:
                child_seen = True
                absent = 0
            else:
                absent += 1
                if absent >= absent_limit:
                    raise ChromeStartupError(
                        "Chrome launcher exit=" + str(code) +
                        ", no V2 browser process, CDP unavailable after " +
                        str(step + 1) + " checks")
        if step + 1 < attempts:
            delay(1)
    raise ChromeStartupError(
        "CDP V2 unavailable after " + str(attempts) +
        " checks; launcher_exit=" + str(last_code) +
        "; child_process_seen=" + ("YES" if child_seen else "NO"))
