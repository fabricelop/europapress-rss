#!/usr/bin/env python3
from apply_editorial_outbox import load, sync_compact, QUEUE

sync_compact(load(QUEUE, {"items": []}))
