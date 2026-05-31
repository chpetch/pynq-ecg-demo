# -*- coding: utf-8 -*-
"""Detection-quality check: capture N seconds from the ECG server WebSocket and
report R-peak count, missed beats (long R-R gaps), and BPM stability.

Usage:  py verification/check_detection.py [board_ip] [seconds]
"""
import asyncio
import json
import sys

import websockets

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.2.99"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
uri = f"ws://{ip}:5000/ws"


async def main():
    rpk_t = []
    bpm_seen = {}
    n = 0
    async with websockets.connect(uri, max_size=None) as ws:
        loop = asyncio.get_event_loop()
        t0 = loop.time()
        while loop.time() - t0 < secs:
            p = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            n += 1
            if p["rpeak"]:
                rpk_t.append(p["timestamp_ms"] / 1000.0)
            b = p["bpm"]
            bpm_seen[b] = bpm_seen.get(b, 0) + 1

    dur = secs
    ints = [round((rpk_t[i + 1] - rpk_t[i]) * 1000) for i in range(len(rpk_t) - 1)]
    # a "missed beat" = an interval noticeably longer than the median (>1.5x)
    missed = 0
    if ints:
        med = sorted(ints)[len(ints) // 2]
        missed = sum(1 for x in ints if x > 1.5 * med)
    print(f"window={dur:.0f}s  packets={n}  R-peaks={len(rpk_t)}")
    print(f"R-R intervals (ms): {ints}")
    print(f"missed-beat gaps (>1.5x median): {missed}")
    print(f"BPM distribution: {dict(sorted(bpm_seen.items()))}")


asyncio.run(main())
