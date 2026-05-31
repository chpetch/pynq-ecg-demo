"""
ps/server.py — PYNQ-Z2 PS server for ECG demo (FastAPI transport).

Streams ECG data over WebSocket (/ws) and accepts config over REST
(/config, /status). All hardware logic lives in ecg_hw.py.

NOTE: the PYNQ-Z2 board used for this demo is offline and has no FastAPI/uvicorn
(only Tornado), so the board runs server_tornado.py instead. This FastAPI server
is kept for hosts that do have the deps; both share ecg_hw.py and expose the same
contract, so the dashboard works against either.

Milestone 5 — pynq_ps_server agent
"""

import asyncio
import signal
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

import ecg_hw

SAMPLE_RATE_HZ = ecg_hw.SAMPLE_RATE_HZ
connected_clients: list[WebSocket] = []


# ---------------------------------------------------------------------------
# Lifespan (startup / shutdown)
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    ecg_hw.load_overlay()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(_shutdown()))

    yield
    await _shutdown()


async def _shutdown() -> None:
    print("Shutting down — closing WebSocket connections...")
    for ws in list(connected_clients):
        try:
            await ws.close()
        except Exception:
            pass
    connected_clients.clear()
    ecg_hw.shutdown()


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="PYNQ ECG Server", version="1.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.websocket("/ws")
async def ws_stream(websocket: WebSocket):
    """Stream ECG data at SAMPLE_RATE_HZ to each connected client."""
    await websocket.accept()
    connected_clients.append(websocket)
    print(f"WebSocket client connected. Total: {len(connected_clients)}")
    last_ts = None
    try:
        while True:
            pkt = ecg_hw.get_telemetry()        # broadcaster: no AXI reads here
            if pkt and pkt.get("timestamp_ms") != last_ts:
                last_ts = pkt["timestamp_ms"]
                await websocket.send_json(pkt)
            await asyncio.sleep(1 / SAMPLE_RATE_HZ)
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        print(f"WebSocket error: {exc}")
    finally:
        if websocket in connected_clients:
            connected_clients.remove(websocket)
        print(f"WebSocket client disconnected. Total: {len(connected_clients)}")


# ---------------------------------------------------------------------------
# REST
# ---------------------------------------------------------------------------

class ConfigRequest(BaseModel):
    bpm_ch_a:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_b:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_c:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_d:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_e:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_f:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_g:         Optional[int] = Field(default=None, ge=30, le=240)
    bpm_ch_h:         Optional[int] = Field(default=None, ge=30, le=240)
    rr_fluct:         Optional[int] = Field(default=None, ge=0,  le=255)
    amp_fluct:        Optional[int] = Field(default=None, ge=0,  le=255)
    detect_threshold: Optional[int] = Field(default=None, ge=0,  le=4095)


@app.post("/config")
async def post_config(req: ConfigRequest):
    written = ecg_hw.apply_config(req.model_dump(exclude_none=True))
    return {"status": "ok", "written": written}


@app.get("/status")
async def get_status():
    return ecg_hw.get_status()


if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=5000, workers=1)
