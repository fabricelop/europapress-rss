#!/usr/bin/env python3
"""Cierra únicamente los Chrome efímeros del editor de Tendencias.

La base parallel_dispatch_v2.py también se usa para imágenes y no se cambia.
Este wrapper recupera un slot cuando su worker Python terminó demasiado
pronto para cerrar todos los procesos Chrome del perfil exacto que creó.
"""
import pathlib
import time

from chrome_cleanup_v2 import cleanup_v2_profile
from chrome_profile_process_v2 import exact_chrome_profile_pids
from parallel_dispatch_v2 import DisposableWorkerPool as BasePool, EPHEMERAL_MARKER


class EditorialWorkerPool(BasePool):
    def _remove_owned(self, slot):
        # Windows/antivirus can hold the last profile handle briefly. The
        # parent's check still proves ownership and zero live Chrome PIDs.
        for attempt in range(3):
            try:
                return super()._remove_owned(slot)
            except PermissionError:
                if attempt == 2:
                    raise
                time.sleep(0.5)

    def reap(self):
        finished = super().reap()
        for job in finished:
            if job.get("profile_deleted"):
                continue
            profile = pathlib.Path(self.profiles[job["slot"]])
            # No cleanup of the authenticated seed, symlinks, junctions or
            # unmarked profiles. Never search for generic Chrome processes.
            owned = (profile.is_dir() and not profile.is_symlink()
                     and not (hasattr(profile, "is_junction") and profile.is_junction())
                     and (profile / EPHEMERAL_MARKER).is_file())
            if not owned:
                continue
            try:
                if exact_chrome_profile_pids(profile):
                    result = cleanup_v2_profile(
                        lambda: exact_chrome_profile_pids(profile))
                    if not result["closed"]:
                        job["profile_cleanup_error"] = "V2_JOB_CHROME_STILL_RUNNING"
                        continue
                self._remove_owned(job["slot"])
                job["profile_deleted"] = True
                job.pop("profile_cleanup_error", None)
            except (OSError, RuntimeError) as exc:
                job["profile_cleanup_error"] = type(exc).__name__[:80]
        return finished
