# -*- coding: utf-8 -*-
"""Multi-client broadcaster verification for the ECG server.

Opens TWO concurrent WebSocket clients, collects packets for a few seconds, and
checks that for matching timestamps both clients see IDENTICAL packets — in
particular identical `rpeak` flags (the multi-client R-peak race must be gone).

Usage:  py verification/ws_multiclient_test.py [board_ip] [seconds]
"""
import asyncio
import json
import sys

import websockets

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.2.99"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
uri = f"ws://{ip}:5000/ws"


async def collect(tag):
    pkts = {}
    async with websockets.connect(uri, max_size=None) as ws:
        loop = asyncio.get_event_loop()
        t0 = loop.time()
        while loop.time() - t0 < secs:
            p = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            pkts[p["timestamp_ms"]] = p
    return tag, pkts


async def main():
    (_, a), (_, b) = await asyncio.gather(collect("A"), collect("B"))
    common = sorted(set(a) & set(b))
    print(f"client A pkts={len(a)}  client B pkts={len(b)}  shared timestamps={len(common)}")
    if not common:
        print("[FAIL] no overlapping timestamps"); sys.exit(1)

    mismatches = [ts for ts in common if a[ts] != b[ts]]
    rpeaks_a = sum(1 for ts in common if a[ts]["rpeak"])
    rpeaks_b = sum(1 for ts in common if b[ts]["rpeak"])
    rpeak_mismatch = [ts for ts in common if a[ts]["rpeak"] != b[ts]["rpeak"]]

    print(f"identical packets on shared ts : {len(common) - len(mismatches)}/{len(common)}")
    print(f"R-peaks seen (A/B) on shared ts: {rpeaks_a}/{rpeaks_b}")
    print(f"R-peak flag mismatches         : {len(rpeak_mismatch)}")

    ok = not mismatches and not rpeak_mismatch
    print("[PASS] both clients receive identical packets + identical R-peaks"
          if ok else "[FAIL] clients diverged — race still present")
    sys.exit(0 if ok else 1)


asyncio.run(main())
