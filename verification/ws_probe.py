# -*- coding: utf-8 -*-
"""Headless probe of the ECG server WebSocket — confirms live ADC is streaming.

Usage:  py verification/ws_probe.py [board_ip] [seconds]
Asserts ecg_raw varies (not a flat/constant value).
"""
import asyncio
import json
import sys

import websockets

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.2.99"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
uri = f"ws://{ip}:5000/ws"


async def main():
    raws, dacs, n = [], [], 0
    async with websockets.connect(uri, max_size=None) as ws:
        loop = asyncio.get_event_loop()
        t0 = loop.time()
        while loop.time() - t0 < secs:
            pkt = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            raws.append(pkt["ecg_raw"])
            dacs.append(pkt["ecg_dac"])
            n += 1
    rate = n / secs
    print(f"packets={n}  rate~{rate:.0f} Hz")
    print(f"ecg_raw : min={min(raws)} max={max(raws)} range={max(raws)-min(raws)}")
    print(f"ecg_dac : min={min(dacs)} max={max(dacs)} range={max(dacs)-min(dacs)}")
    ok = (max(raws) - min(raws)) > 50
    print("LIVE ADC STREAMING — varies" if ok else "WARN: ecg_raw flat (check sampler/loopback)")
    sys.exit(0 if ok else 1)


asyncio.run(main())
