#!/usr/bin/env python3
"""Retired: no push notifications for TTiTTulares or TTendencias.

The user explicitly disabled the green-image alerts on 2026-10-14.
This compatibility entry point must stay a no-op even if an old scheduled
or manual workflow attempts to run it. Pinned-panel image statuses still work.
"""
import sys

if __name__ == "__main__":
    print("TT_GREEN_NOTIFICATIONS_DISABLED" +
          (" SELFTEST_OK" if "selftest" in sys.argv else ""))
