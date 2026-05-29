"""
ps/server.py — PYNQ-Z2 PS server for ECG demo
Loads PL bitstream, reads AXI registers, streams ECG data over WebSocket,
and accepts config commands over REST.

Milestone 5 — pynq_ps_server agent
"""

import asyncio
import os
import signal
import threading
import time
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator, model_validator

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BITSTREAM_PATH = "ecg_demo.bit"
AXI_BASE = 0x43C00000
SAMPLE_RATE_HZ = 360
DEFAULT_DETECT_THRESHOLD = 2983  # 0xBA7 per algorithm_spec.md
SENTINEL_VALUES = (0xDEADBEEF, 0xFFFFFFFF)

# AD7991-0 (PMOD AD2) constants — read via Xilinx AXI IIC IP at 0x41600000
AD7991_I2C_ADDR  = 0x28
AD7991_CFG_CH0   = 0x10   # enable CH0 only, Vcc reference, no filters


# ---------------------------------------------------------------------------
# AXI Register Map — offsets from handoffs/register_map.md
# ---------------------------------------------------------------------------

class ECGRegisters:
    BPM_CH_A         = 0x00
    RR_FLUCT         = 0x04
    AMP_FLUCT        = 0x08
    BPM_CH_B         = 0x0C
    BPM_CH_C         = 0x10
    BPM_CH_D         = 0x14
    BPM_CH_E         = 0x18
    BPM_CH_F         = 0x1C
    BPM_CH_G         = 0x20
    BPM_CH_H         = 0x24
    ECG_RAW          = 0x28
    ECG_FILTERED     = 0x2C
    BPM_OUT          = 0x30
    RPEAK_COUNT      = 0x34
    DETECT_THRESHOLD = 0x38
    STATUS           = 0x3C
    ECG_DAC          = 0x40


# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

overlay = None       # pynq.Overlay instance
axi = None           # AXI MMIO handle (overlay.axi_ecg_ctrl)
sampler = None       # AD7991Sampler instance (PS-side ADC reader)
start_time_ms: float = 0.0
prev_rpeak_count: int = 0
connected_clients: list[WebSocket] = []


# ---------------------------------------------------------------------------
# AD7991 sampler (PS-side, drives Xilinx AXI IIC IP)
# ---------------------------------------------------------------------------

class AD7991Sampler:
    """Background thread that reads the AD7991-0 over the Xilinx AXI IIC IP
    and writes each 12-bit sample to ECG_RAW (0x28) on the custom block.

    Replaces the deleted custom RTL i2c_adc_driver.v — vendor IP handles
    all the I2C protocol details (start/stop/ACK/clock-stretch). PS owns
    the sample rate; ~360 Hz is well within the AD7991's conversion budget
    and the AXI IIC's 100 kHz bus rate (each 2-byte read takes ~270 us
    plus a config write ~180 us = ~450 us per sample, 16% utilisation).
    """

    def __init__(self, axi_iic, axi_ctrl):
        self._iic       = axi_iic
        self._axi_ctrl  = axi_ctrl
        self._stop_evt  = threading.Event()
        self._thread    = None
        self._error_logged = False

    def start(self) -> None:
        self._stop_evt.clear()
        self._thread = threading.Thread(
            target=self._loop, name="AD7991Sampler", daemon=True)
        self._thread.start()
        print(f"AD7991Sampler started at {SAMPLE_RATE_HZ} Hz "
              f"(slave 0x{AD7991_I2C_ADDR:02X}, cfg 0x{AD7991_CFG_CH0:02X})")

    def stop(self) -> None:
        self._stop_evt.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        print("AD7991Sampler stopped.")

    def _loop(self) -> None:
        period_s  = 1.0 / SAMPLE_RATE_HZ
        next_tick = time.monotonic()
        while not self._stop_evt.is_set():
            try:
                self._iic.send(AD7991_I2C_ADDR, [AD7991_CFG_CH0], 1)
                data = self._iic.receive(AD7991_I2C_ADDR, 2)
                raw  = ((data[0] & 0x0F) << 8) | (data[1] & 0xFF)
                self._axi_ctrl.write(ECGRegisters.ECG_RAW, raw)
            except Exception as exc:
                if not self._error_logged:
                    print(f"AD7991 sample error (suppressing further): {exc}")
                    self._error_logged = True

            next_tick += period_s
            delta = next_tick - time.monotonic()
            if delta > 0:
                time.sleep(delta)
            else:
                next_tick = time.monotonic()  # we slipped; resync


# ---------------------------------------------------------------------------
# AXI read/write helpers
# ---------------------------------------------------------------------------

def axi_read(offset: int) -> int:
    """Read a 32-bit register at the given word offset."""
    value = axi.read(offset)
    if value in SENTINEL_VALUES:
        print(f"WARNING: axi_read(0x{offset:02X}) returned 0x{value:08X} — PL connectivity issue?")
    return value


def axi_write(offset: int, value: int) -> None:
    """Write a 32-bit value to the given word offset."""
    axi.write(offset, value)


# ---------------------------------------------------------------------------
# Overlay initialisation
# ---------------------------------------------------------------------------

def load_overlay() -> None:
    """Load the PL bitstream; exit with error if not present."""
    global overlay, axi, sampler

    if not os.path.exists(BITSTREAM_PATH):
        print(f"ERROR: {BITSTREAM_PATH} not found. Copy bitstream from Vivado export first.")
        raise SystemExit(1)

    from pynq import Overlay as PynqOverlay  # imported here so unit tests can mock

    overlay = PynqOverlay(BITSTREAM_PATH)
    axi = overlay.axi_ecg_ctrl

    # Write the algorithm-specified default threshold at startup
    axi_write(ECGRegisters.DETECT_THRESHOLD, DEFAULT_DETECT_THRESHOLD)
    print(f"Overlay loaded. DETECT_THRESHOLD set to {DEFAULT_DETECT_THRESHOLD} (0x{DEFAULT_DETECT_THRESHOLD:03X}).")

    # Start PS-side ADC sampler using the Xilinx AXI IIC IP.
    # The IP is auto-discovered by PYNQ as overlay.axi_iic_0 (named by the
    # block-design instance in create_project.tcl).
    try:
        axi_iic = overlay.axi_iic_0
    except AttributeError:
        print("WARNING: axi_iic_0 not found in overlay — ECG_RAW will not be sampled.")
        print("         Did you rebuild the bitstream after the I2C IP migration?")
        return

    sampler = AD7991Sampler(axi_iic, axi)
    sampler.start()


# ---------------------------------------------------------------------------
# Lifespan (startup / shutdown)
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    global start_time_ms, prev_rpeak_count

    load_overlay()
    start_time_ms = time.monotonic() * 1000
    prev_rpeak_count = axi_read(ECGRegisters.RPEAK_COUNT) & 0xFFFF

    # Install graceful shutdown handlers
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(_shutdown()))

    yield  # server runs here

    await _shutdown()


async def _shutdown() -> None:
    """Close all WebSocket connections, stop ADC sampler, release the overlay."""
    print("Shutting down — closing WebSocket connections...")
    for ws in list(connected_clients):
        try:
            await ws.close()
        except Exception:
            pass
    connected_clients.clear()

    if sampler is not None:
        try:
            sampler.stop()
        except Exception:
            pass

    if overlay is not None:
        try:
            overlay.free()
        except Exception:
            pass
    print("Overlay released.")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="PYNQ ECG Server", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# WebSocket — /ws
# ---------------------------------------------------------------------------

@app.websocket("/ws")
async def ws_stream(websocket: WebSocket):
    """Stream ECG data at 360 Hz to each connected client."""
    global prev_rpeak_count

    await websocket.accept()
    connected_clients.append(websocket)
    print(f"WebSocket client connected. Total: {len(connected_clients)}")

    try:
        while True:
            now_ms = time.monotonic() * 1000 - start_time_ms

            # Read all relevant registers
            ecg_raw      = axi_read(ECGRegisters.ECG_RAW)      & 0xFFF
            ecg_dac      = axi_read(ECGRegisters.ECG_DAC)      & 0xFFF
            ecg_filtered = axi_read(ECGRegisters.ECG_FILTERED) & 0xFFF
            bpm_out      = axi_read(ECGRegisters.BPM_OUT)      & 0xFF
            rpeak_count  = axi_read(ECGRegisters.RPEAK_COUNT)  & 0xFFFF
            status_reg   = axi_read(ECGRegisters.STATUS)       & 0x03

            # Detect new R-peak by counter change (handles wrap-around)
            rpeak_fired = rpeak_count != prev_rpeak_count
            prev_rpeak_count = rpeak_count

            packet = {
                "timestamp_ms": round(now_ms, 3),
                "ecg_raw":      ecg_raw,
                "ecg_dac":      ecg_dac,
                "ecg_filtered": ecg_filtered,
                "bpm":          bpm_out,
                "rpeak":        rpeak_fired,
                "status": {
                    "signal_present": bool(status_reg & 0x01),
                    "lead_off":       bool(status_reg & 0x02),
                },
            }

            await websocket.send_json(packet)
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
# Pydantic models for REST
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


# Map field name → (register offset, mask)
_FIELD_MAP: dict[str, tuple[int, int]] = {
    "bpm_ch_a":         (ECGRegisters.BPM_CH_A,         0xFF),
    "bpm_ch_b":         (ECGRegisters.BPM_CH_B,         0xFF),
    "bpm_ch_c":         (ECGRegisters.BPM_CH_C,         0xFF),
    "bpm_ch_d":         (ECGRegisters.BPM_CH_D,         0xFF),
    "bpm_ch_e":         (ECGRegisters.BPM_CH_E,         0xFF),
    "bpm_ch_f":         (ECGRegisters.BPM_CH_F,         0xFF),
    "bpm_ch_g":         (ECGRegisters.BPM_CH_G,         0xFF),
    "bpm_ch_h":         (ECGRegisters.BPM_CH_H,         0xFF),
    "rr_fluct":         (ECGRegisters.RR_FLUCT,         0xFF),
    "amp_fluct":        (ECGRegisters.AMP_FLUCT,        0xFF),
    "detect_threshold": (ECGRegisters.DETECT_THRESHOLD, 0xFFF),
}


# ---------------------------------------------------------------------------
# REST — POST /config
# ---------------------------------------------------------------------------

@app.post("/config")
async def post_config(req: ConfigRequest):
    """
    Write config registers for any fields supplied in the request body.
    Only fields present (non-null) are written. Returns list of written fields.
    """
    written: list[str] = []

    req_dict = req.model_dump(exclude_none=True)
    for field_name, value in req_dict.items():
        if field_name not in _FIELD_MAP:
            continue
        offset, mask = _FIELD_MAP[field_name]
        axi_write(offset, int(value) & mask)
        written.append(field_name)

    return {"status": "ok", "written": written}


# ---------------------------------------------------------------------------
# REST — GET /status
# ---------------------------------------------------------------------------

@app.get("/status")
async def get_status():
    """Return current register state; useful for GUI initialisation."""
    status_reg = axi_read(ECGRegisters.STATUS) & 0x03

    return {
        "bpm_ch_a":         axi_read(ECGRegisters.BPM_CH_A)         & 0xFF,
        "rr_fluct":         axi_read(ECGRegisters.RR_FLUCT)         & 0xFF,
        "amp_fluct":        axi_read(ECGRegisters.AMP_FLUCT)        & 0xFF,
        "detect_threshold": axi_read(ECGRegisters.DETECT_THRESHOLD) & 0xFFF,
        "bpm_out":          axi_read(ECGRegisters.BPM_OUT)          & 0xFF,
        "signal_present":   bool(status_reg & 0x01),
    }


# ---------------------------------------------------------------------------
# Entry point (used by start_server.sh via uvicorn CLI, but also direct run)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=5000, workers=1)
