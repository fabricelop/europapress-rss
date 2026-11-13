#!/usr/bin/env python3
"""Hide windows of the isolated V2 ChromeProfile only.

Chrome in normal headed mode preserves the authenticated browser behaviour
observed in V2; Windows STARTUPINFO requests SW_HIDE before its first window.
A short-lived observer hides only HWNDs owned by ChromeProfile V2 processes.
Never interacts with other Chrome windows (in particular V1).
"""
import os
import subprocess
import threading
import time

SW_HIDE = 0


def startupinfo_hidden():
    """Request hidden startup for headed chrome.exe on Windows."""
    if os.name != "nt":
        return None
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = SW_HIDE
    return info


def hide_windows_for_pids(pids):
    """Hide existing top-level windows for exact verified V2 process IDs."""
    import ctypes
    from ctypes import wintypes
    wanted = {int(pid) for pid in pids}
    if not wanted:
        return 0
    user32 = ctypes.windll.user32
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND,
                                                 ctypes.POINTER(wintypes.DWORD)]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    hidden = []

    @callback_type
    def callback(hwnd, param):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in wanted and bool(user32.IsWindowVisible(hwnd)):
            user32.ShowWindow(hwnd, SW_HIDE)
            hidden.append(pid.value)
        return True

    if not user32.EnumWindows(callback, 0):
        raise OSError("Cannot enumerate Windows desktop windows")
    return len(hidden)


def visible_windows_for_pids(pids):
    """Count visible HWNDs owned by precisely the V2-profile processes."""
    import ctypes
    from ctypes import wintypes
    wanted = {int(pid) for pid in pids}
    if not wanted:
        return 0
    user32 = ctypes.windll.user32
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND,
                                                 ctypes.POINTER(wintypes.DWORD)]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    visible = []

    @callback_type
    def callback(hwnd, param):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in wanted and user32.IsWindowVisible(hwnd):
            visible.append(pid.value)
        return True

    if not user32.EnumWindows(callback, 0):
        raise OSError("Cannot verify hidden Chrome V2 windows")
    return len(visible)


class V2WindowHider:
    """Maintain hidden V2 windows across navigation / Chrome-created windows."""

    def __init__(self, find_pids, *, interval=0.8):
        self.find_pids = find_pids
        self.interval = interval
        self.closed = threading.Event()
        self.thread = None
        self.last_error = None
        self.windows_hidden = 0

    def _watch(self):
        while not self.closed.is_set():
            try:
                self.windows_hidden += hide_windows_for_pids(self.find_pids())
            except Exception as exc:
                self.last_error = type(exc).__name__ + ": " + str(exc)[:120]
            self.closed.wait(self.interval)

    def start(self):
        if os.name != "nt":
            raise RuntimeError("Hidden headed Chrome is Windows-only")
        self.thread = threading.Thread(target=self._watch, name="TTActualidadV2ChromeHider",
                                       daemon=True)
        self.thread.start()
        return self

    def stop(self):
        self.closed.set()
        if self.thread:
            self.thread.join(timeout=3)
