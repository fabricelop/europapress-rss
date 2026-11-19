"""Fast, exact News V2 Chrome ownership checks without PowerShell/CIM polling.

Never infer ownership from a process name or a CDP port alone. Only Chrome
processes whose explicit --user-data-dir equals the disposable News profile
may be closed. Access errors fail closed rather than returning an empty set.
"""
from __future__ import annotations

import ntpath

import psutil


def _profile_arg(argv):
    if not isinstance(argv, (tuple, list)):
        return None
    for position, argument in enumerate(argv):
        if not isinstance(argument, str):
            continue
        if argument.lower().startswith('--user-data-dir='):
            value = argument.split('=', 1)[1].strip('"')
        elif argument.lower() == '--user-data-dir' and position + 1 < len(argv):
            value = str(argv[position + 1]).strip('"')
        else:
            continue
        return ntpath.normcase(ntpath.normpath(value)) if value else None
    return None


def chrome_profile_pids(profile, *, process_iter=None):
    """Identify only Chrome processes with the *exact* News profile path."""
    expected = ntpath.normcase(ntpath.normpath(str(profile)))
    scan = process_iter or psutil.process_iter
    owned = set()
    try:
        for process in scan(['pid', 'name', 'cmdline']):
            try:
                info = process.info
                if str(info.get('name') or '').lower() != 'chrome.exe':
                    continue
                argv = info.get('cmdline')
                if not argv:
                    raise RuntimeError('NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE')
                if _profile_arg(argv) == expected:
                    pid = info.get('pid')
                    if type(pid) is not int or pid <= 0:
                        raise RuntimeError('NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE')
                    owned.add(pid)
            except (psutil.NoSuchProcess, psutil.ZombieProcess):
                continue
            except psutil.AccessDenied:
                raise RuntimeError('NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE') from None
    except (OSError, psutil.Error):
        raise RuntimeError('NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE') from None
    return owned


def listener_pids(port, *, connections=None):
    """Owner PIDs of the exact local CDP listening port, without PowerShell."""
    if type(port) is not int or port < 1024 or port > 65535 or port in (9223, 9234):
        raise RuntimeError('NEWS_CDP_PORT_INVALID')
    try:
        entries = (connections or psutil.net_connections)(kind='tcp')
        return {entry.pid for entry in entries
                if entry.status == psutil.CONN_LISTEN and entry.laddr
                and entry.laddr.port == port
                and entry.laddr.ip in ('127.0.0.1', '0.0.0.0')
                and type(entry.pid) is int and entry.pid > 0}
    except (OSError, psutil.Error, AttributeError, TypeError):
        raise RuntimeError('NEWS_CDP_OWNER_INSPECTION_FAILED') from None
