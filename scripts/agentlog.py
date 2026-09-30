#!/usr/bin/env python3
"""Condense the agent worker's JSON log to STT / tool / metrics / error lines.

    python scripts/agentlog.py [/tmp/smoke_agent.log]
"""

import json
import sys

KEEP = ("STT", "dropping", "dedup", "METRICS", "received job")

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/smoke_agent.log"
for line in open(path, encoding="utf-8", errors="replace"):
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    msg = d.get("message", "")
    if msg.startswith(KEEP) or d.get("level") == "ERROR":
        print(d.get("timestamp", "")[11:23], d.get("room", "")[-4:], msg[:220].replace("\n", " "))
