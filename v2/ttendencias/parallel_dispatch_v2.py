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
import threading
import time
from datetime import datetime, timezone

from chrome_profile_process_v2 import exact_chrome_profile_pids
from chrome_cleanup_v2 import cleanup_v2_profile


MIN_JOB_FREE_BYTES = 8 * 1024 ** 3
MAX_JOB_SESSION_SECONDS = 480
EPHEMERAL_MARKER = "tt-v2-ephemeral-owned.marker"


def _ignore_chrome_cache(directory, contents):
    # Cookies, Local State and actual authentication MUST remain in the copy.
    disposable = {"Cache", "Code Cache", "GPUCache", "GrShaderCache",
                  "ShaderCache", "Crashpad", "component_crx_cache",
                  "DevToolsActivePort", "SingletonLock", "SingletonCookie",
                  "SingletonSocket", "lockfile"}
    return [name for name in contents if name in disposable]


def prepare_profiles(base, count, *, source_running):
    """Provision distinct Chrome data dirs while source is completely closed.

    Never overwrite an existing worker profile. A verified complete staging
    directory may be used as its own slot if Windows blocks renaming it.
    An incomplete copy is never silently reused or deleted.
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
        selected = destination
        if destination.exists():
            if not marker.is_file():
                raise RuntimeError("V2_PARALLEL_PROFILE_INCOMPLETE_" + str(index))
        else:
            if temporary.exists():
                # A previous Windows rename may have failed with WinError 5
                # AFTER copy and marker succeeded. Keep the fully prepared
                # directory instead of copying credentials again or deleting it.
                if not (temporary / marker.name).is_file():
                    raise RuntimeError("V2_PARALLEL_PROFILE_PARTIAL_COPY_" + str(index))
                selected = temporary
            else:
                shutil.copytree(base, temporary, ignore=_ignore_chrome_cache)
                (temporary / marker.name).write_text(
                    "TT_V2_ISOLATED_PROFILE\n", encoding="utf-8")
                try:
                    temporary.replace(destination)
                except PermissionError:
                    # NTFS/antivirus can forbid directory rename although
                    # the staged profile itself is complete and writable.
                    # The worker accepts an arbitrary absolute profile path.
                    selected = temporary
        if not (selected / marker.name).is_file() and selected != base:
            raise RuntimeError("V2_PARALLEL_PROFILE_NOT_VERIFIED_" + str(index))
        profiles.append(selected)
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


class DisposableWorkerPool(WorkerPool):
    """Clone the authenticated seed per job; discard its exact Chrome profile.

    Profiles occupy a bounded number of named slots, not one directory per
    trend. A marker proves that a slot belongs to this pool. A profile that
    Chrome still uses, or whose ownership cannot be verified, is never erased.
    """

    def __init__(self, seed, count, *, source_running, env_key, logs_dir,
                 max_session_seconds=MAX_JOB_SESSION_SECONDS, clock=time.monotonic):
        self.seed = pathlib.Path(seed)
        self.source_running = source_running
        if not 1 <= count <= 6:
            raise ValueError("V2_PARALLEL_WORKERS_OUT_OF_BOUNDS")
        if not self.seed.is_dir():
            raise RuntimeError("V2_PARALLEL_AUTHENTICATED_BASE_PROFILE_MISSING")
        if source_running():
            raise RuntimeError("V2_PARALLEL_BASE_CHROME_BUSY")
        if not 1 <= max_session_seconds <= MAX_JOB_SESSION_SECONDS:
            raise ValueError("V2_SESSION_TIMEOUT_OUT_OF_BOUNDS")
        self.max_session_seconds = max_session_seconds
        self.clock = clock
        profiles = [self.seed.with_name(self.seed.name + "-Job-%02d" % index)
                    for index in range(count)]
        super().__init__(profiles, env_key=env_key, logs_dir=logs_dir)

    def available_slot(self):
        # A failed Chrome cleanup must quarantine only its own slot. Other
        # independent slots can continue processing the Top30; never clone
        # over a profile that still has an owned Chrome process.
        for slot, profile in enumerate(self.profiles):
            if slot in self.active:
                continue
            if ((profile / EPHEMERAL_MARKER).is_file()
                    and exact_chrome_profile_pids(profile)):
                continue
            return slot
        return None

    def _remove_owned(self, slot):
        profile = self.profiles[slot]
        if not profile.exists() and not profile.is_symlink():
            return
        if (profile.is_symlink() or
                (hasattr(profile, "is_junction") and profile.is_junction()) or
                not profile.is_dir() or
                not (profile / EPHEMERAL_MARKER).is_file()):
            raise RuntimeError("V2_JOB_PROFILE_OWNERSHIP_UNVERIFIED")
        if exact_chrome_profile_pids(profile):
            raise RuntimeError("V2_JOB_PROFILE_CHROME_STILL_RUNNING")
        shutil.rmtree(profile)

    def _prepare(self, slot):
        if self.source_running():
            raise RuntimeError("V2_PARALLEL_BASE_CHROME_BUSY")
        self._remove_owned(slot)
        if shutil.disk_usage(self.seed).free < MIN_JOB_FREE_BYTES:
            raise RuntimeError("V2_JOB_DISK_SPACE_LOW_NO_NEW_CHROME")
        profile = self.profiles[slot]
        profile.mkdir(exist_ok=False)
        try:
            (profile / EPHEMERAL_MARKER).write_text("TT_V2_EPHEMERAL_JOB\n", encoding="utf-8")
            shutil.copytree(self.seed, profile, dirs_exist_ok=True,
                            ignore=_ignore_chrome_cache)
        except Exception:
            # The newly owned slot was never launched. A failed seed copy is
            # not allowed to accumulate another browser-sized partial clone.
            if (profile / EPHEMERAL_MARKER).is_file():
                self._remove_owned(slot)
            elif (profile.is_dir() and not profile.is_symlink() and
                  not (hasattr(profile, "is_junction") and profile.is_junction()) and
                  not exact_chrome_profile_pids(profile)):
                # Marker creation itself can fail when the disk is truly full.
                # The directory was created exclusively by this invocation.
                shutil.rmtree(profile)
            raise

    def spawn(self, script, args, *, trend_id, revision, attempt=None):
        slot = self.available_slot()
        if slot is None or (trend_id, revision) in self.busy_keys:
            return False
        self._prepare(slot)
        try:
            result = super().spawn(script, args, trend_id=trend_id,
                                   revision=revision, attempt=attempt)
            if result:
                self.active[slot]["started_monotonic"] = self.clock()
                watch = threading.Timer(self.max_session_seconds, self._expire_slot,
                                        args=(slot, self.active[slot]["process"]))
                watch.daemon = True
                self.active[slot]["watchdog"] = watch
                watch.start()
            return result
        except Exception:
            # Popen may fail before the worker has created a Chrome process.
            # Only discard the exact marked slot after a fresh PID check.
            self._remove_owned(slot)
            raise

    def _expire_slot(self, slot, proc):
        task = self.active.get(slot)
        if not task or task["process"] is not proc or proc.poll() is not None:
            return
        # An independent timer runs even while the dispatcher is waiting for
        # a remote queue read: no chat can pin a worker indefinitely.
        task["timed_out"] = True
        try:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            pass
        if proc.poll() is None:
            task["timeout_cleanup_error"] = "V2_SESSION_PYTHON_STILL_RUNNING"
            return
        profile = self.profiles[slot]
        if profile.is_dir() and (profile / EPHEMERAL_MARKER).is_file():
            try:
                closed = cleanup_v2_profile(lambda: exact_chrome_profile_pids(profile))
                if not closed["closed"]:
                    task["timeout_cleanup_error"] = "V2_SESSION_CHROME_STILL_RUNNING"
            except (OSError, RuntimeError):
                task["timeout_cleanup_error"] = "V2_SESSION_CHROME_CLEANUP_UNVERIFIED"

    def reap(self):
        for slot, task in list(self.active.items()):
            if (task["process"].poll() is None and
                    self.clock() - task.get("started_monotonic", self.clock()) >=
                    self.max_session_seconds):
                self._expire_slot(slot, task["process"])
        finished = super().reap()
        for job in finished:
            watch = job.pop("watchdog", None)
            if watch:
                watch.cancel()
            if job.get("timed_out"):
                job["exit_code"] = 124
            if job.get("timeout_cleanup_error"):
                job["profile_cleanup_error"] = job["timeout_cleanup_error"]
            try:
                self._remove_owned(job["slot"])
                job["profile_deleted"] = True
            except (OSError, RuntimeError) as exc:
                # Preserve all evidence and the in-use profile; do not hide a
                # cleanup failure behind an otherwise successful editor job.
                job["profile_cleanup_error"] = str(exc)[:180]
                job["profile_deleted"] = False
        return finished

    def wait_for_completion(self):
        """Shutdown observes the watchdog and returns every finished child."""
        finished = []
        while self.active:
            finished.extend(self.reap())
            if self.active:
                time.sleep(1)
        return finished
