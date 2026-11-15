#!/usr/bin/env python3
"""Bounded independent Chrome processes for V2; never shares a live profile.

Slots are cloned from the already authenticated *local* V2 Chrome profile.
The first slot keeps the original profile. Each subprocess owns one slot,
one ChatGPT chat and one exact trend/revision; the dispatcher owns no browser.
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone


def _ignore_chrome_cache(directory, contents):
    # Cookies, Local State and actual authentication MUST remain in the copy.
    disposable = {"Cache", "Code Cache", "GPUCache", "GrShaderCache",
                  "ShaderCache", "Crashpad", "component_crx_cache",
                  "DevToolsActivePort", "SingletonLock", "SingletonCookie",
                  "SingletonSocket", "lockfile"}
    return [name for name in contents if name in disposable]


def prepare_profiles(base, count, *, source_running):
    """Provision distinct Chrome data dirs while source is completely closed.

    Never overwrite an existing worker profile. An interrupted copy is treated
    as a safety stop, not silently reused or deleted.
    """
    base = pathlib.Path(base)
    if not 1 <= count <= 6:
        raise ValueError("V2_PARALLEL_WORKERS_OUT_OF_BOUNDS")
    if not base.is_dir():
        raise RuntimeError("V2_PARALLEL_AUTHENTICATED_BASE_PROFILE_MISSING")
    if source_running():
        raise RuntimeError("V2_PARALLEL_BASE_CHROME_BUSY")
    profiles = [base]
    for index in range(1, count):
        destination = base.with_name(base.name + "-Parallel-%02d" % index)
        marker = destination / "tt-v2-parallel-ready.marker"
        temporary = destination.with_name(destination.name + ".building")
        if destination.exists():
            if not marker.is_file():
                raise RuntimeError("V2_PARALLEL_PROFILE_INCOMPLETE_" + str(index))
        else:
            if temporary.exists():
                raise RuntimeError("V2_PARALLEL_PROFILE_PARTIAL_COPY_" + str(index))
            shutil.copytree(base, temporary, ignore=_ignore_chrome_cache)
            (temporary / marker.name).write_text("TT_V2_ISOLATED_PROFILE\n", encoding="utf-8")
            temporary.replace(destination)
        profiles.append(destination)
    return profiles


class WorkerPool:
    def __init__(self, profiles, *, env_key, logs_dir):
        if not profiles or env_key not in ("TT_V2_EDITORIAL_PROFILE", "TT_V2_IMAGE_PROFILE"):
            raise ValueError("V2_PARALLEL_POOL_INVALID")
        self.profiles = list(profiles)
        self.env_key = env_key
        self.logs_dir = pathlib.Path(logs_dir)
        self.active = {}

    @property
    def busy_keys(self):
        return {(task["trend_id"], task["revision"]) for task in self.active.values()}

    def available_slot(self):
        return next((i for i in range(len(self.profiles)) if i not in self.active), None)

    def spawn(self, script, args, *, trend_id, revision, attempt=None):
        slot = self.available_slot()
        if slot is None or (trend_id, revision) in self.busy_keys:
            return False
        if not self.profiles[slot].is_dir():
            raise RuntimeError("V2_PARALLEL_SLOT_PROFILE_NOT_PRESENT")
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        tag = re.sub(r"[^a-zA-Z0-9_.-]", "_", trend_id)
        attempt_tag = "-a%d" % attempt if attempt is not None else ""
        logfile = self.logs_dir / ("%s-r%d%s.log" % (tag, revision, attempt_tag))
        env = os.environ.copy()
        env[self.env_key] = str(self.profiles[slot])
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        startupinfo = None
        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0  # SW_HIDE, incluso el Python hijo.
        with logfile.open("a", encoding="utf-8") as output:
            output.write("V2_PARALLEL_STARTED=" + datetime.now(timezone.utc).isoformat() + "\n")
            output.flush()
            proc = subprocess.Popen([sys.executable, str(script), *map(str, args)],
                                    cwd=str(pathlib.Path(script).parent), env=env,
                                    stdout=output, stderr=subprocess.STDOUT,
                                    creationflags=flags, startupinfo=startupinfo)
        self.active[slot] = {"process": proc, "trend_id": trend_id,
                             "revision": revision, "attempt": attempt,
                             "log": str(logfile), "slot": slot}
        return True

    def reap(self):
        finished = []
        for slot, task in list(self.active.items()):
            exit_code = task["process"].poll()
            if exit_code is None:
                continue
            result = {k: v for k, v in task.items() if k != "process"}
            result["exit_code"] = exit_code
            finished.append(result)
            del self.active[slot]
        return finished

    def wait_for_completion(self):
        """Do not abandon or terminate chats when an enable flag changes."""
        while self.active:
            for task in self.active.values():
                task["process"].wait(timeout=None)
            self.reap()
