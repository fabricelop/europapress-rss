#!/usr/bin/env python3
"""Cierre de procesos Chrome estrictamente del perfil V2, con comprobación.

No examina Chrome genérico: find_pids debe devolver ÚNICAMENTE procesos que
incluyen --user-data-dir=<LOCALAPPDATA>/TTActualidadV2/ChromeProfile.
Se invoca desde una sesión que comprobó previamente que el perfil estaba libre
y mantiene el bloqueo exclusivo del consumidor.
"""
import subprocess
import time


def taskkill_v2_pid(pid):
    """Cerrar el árbol de UN PID que previamente fue identificado como V2."""
    if not isinstance(pid, int) or pid <= 0:
        raise ValueError("PID de Chrome V2 inválido")
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                            capture_output=True, timeout=15, creationflags=flags)
    return result.returncode


def cleanup_v2_profile(find_pids, *, kill_pid=taskkill_v2_pid,
                       sleep=time.sleep, max_rounds=15):
    """Reintentar cierre de hijos tardíos hasta dos escaneos vacíos seguidos.

    Al inspeccionar de nuevo cada vuelta no se dejan escapar procesos hijos
    nacidos después del primer snapshot. Nunca se actúa sobre PID sin verificar
    su pertenencia al perfil V2 en ese mismo escaneo.
    """
    if not isinstance(max_rounds, int) or max_rounds < 2:
        raise ValueError("Se requieren al menos dos inspecciones")
    quiet_rounds = 0
    observed = set()
    failures = {}
    for attempt in range(max_rounds):
        live = set(map(int, find_pids()))
        if not live:
            quiet_rounds += 1
            if quiet_rounds >= 2:
                return {"closed": True, "remaining": [], "seen": sorted(observed),
                        "kill_failures": failures, "rounds": attempt + 1}
        else:
            quiet_rounds = 0
            observed.update(live)
            for pid in sorted(live):
                try:
                    code = kill_pid(pid)
                except (OSError, subprocess.TimeoutExpired) as exc:
                    failures[str(pid)] = type(exc).__name__
                else:
                    if code not in (0, 128, 255):
                        failures[str(pid)] = "taskkill_exit_" + str(code)
        if attempt + 1 < max_rounds:
            sleep(1)
    final = sorted(set(map(int, find_pids())))
    return {"closed": not final, "remaining": final, "seen": sorted(observed),
            "kill_failures": failures, "rounds": max_rounds}
