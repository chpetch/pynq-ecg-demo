"""
pc/mock_server.py — Mock PYNQ-Z2 ECG Board Server
===================================================
Simulates ps/server.py so the Streamlit dashboard can be tested on a PC
without hardware.  Generates synthetic ECG using the same FIR coefficients
and R-peak detector parameters as the RTL implementation.

Usage
-----
    pip install -r requirements.txt      # includes fastapi, uvicorn, numpy, scipy
    python mock_server.py

Then open the dashboard and set Board IP to:  localhost
    streamlit run dashboard.py

Endpoints (identical to ps/server.py)
--------------------------------------
    WS   ws://localhost:5000/ws          360 Hz ECG packet stream
    GET  http://localhost:5000/status    Current config JSON
    POST http://localhost:5000/config    Update config registers
"""

import asyncio
import time

import numpy as np
from scipy import signal as scipy_signal
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# ---------------------------------------------------------------------------
# Constants — must match handoffs/algorithm_spec.md and handoffs/register_map.md
# ---------------------------------------------------------------------------
FS                   = 360    # Hz
BUFFER_BEATS         = 8      # beats to pre-generate per buffer refill
REFRACTORY_SAMPLES   = 72     # 200 ms at 360 Hz
DEFAULT_THRESHOLD    = 2983   # 0.70 × max(filtered) from algorithm_spec.md
DAC_OUT_LO, DAC_OUT_HI = 300, 3800  # 12-bit output window

# Q1.15 FIR coefficients — verbatim from handoffs/algorithm_spec.md
_FIR_Q15 = np.array([
    -56, -31,  22, 112, 197, 180,  -36, -459, -921, -1094, -622,
    682, 2676, 4867, 6577, 7224, 6577, 4867, 2676,  682,  -622,
    -1094, -921, -459, -36, 180, 197, 112,  22,  -31,  -56,
], dtype=np.float64) / 32768.0   # float version for scipy lfilter

# ---------------------------------------------------------------------------
# Live config — updated by POST /config
# ---------------------------------------------------------------------------
_config: dict = {
    "bpm_ch_a":         60,
    "rr_fluct":         0,
    "amp_fluct":        0,
    "detect_threshold": DEFAULT_THRESHOLD,
}

# ---------------------------------------------------------------------------
# ECG waveform synthesis
# ---------------------------------------------------------------------------

def _make_beat(bpm: int, amp: float = 1.0) -> np.ndarray:
    """Single ECG beat in float, Gaussian-composite morphology, range ≈ [-0.1, 1.0]."""
    n = max(36, int(round(FS * 60.0 / bpm)))
    t = np.linspace(0, 1, n, endpoint=False)
    p  =  0.12 * amp * np.exp(-((t - 0.16)**2) / (2 * 0.025**2))
    q  = -0.07 * amp * np.exp(-((t - 0.35)**2) / (2 * 0.008**2))
    r  =  1.00 * amp * np.exp(-((t - 0.40)**2) / (2 * 0.010**2))
    s  = -0.12 * amp * np.exp(-((t - 0.46)**2) / (2 * 0.008**2))
    tw =  0.25 * amp * np.exp(-((t - 0.63)**2) / (2 * 0.050**2))
    return p + q + r + s + tw


def _generate_buffer(
    bpm: int, rr_fluct: int, amp_fluct: int, detect_threshold: int
) -> tuple:
    """
    Generate BUFFER_BEATS beats of ECG.
    Returns: (raw_12, dac_12, filt_12, rpeaks, bpm_val) as numpy arrays.
    All sample arrays are int32 in [0, 4095].
    rpeaks is bool.  bpm_val is int.
    """
    beats = []
    for _ in range(BUFFER_BEATS):
        # RR jitter (±12 % of nominal beat length)
        jitter_samples = 0
        if rr_fluct > 0:
            frac = (rr_fluct / 255.0) * 0.12
            jitter_samples = int(np.random.uniform(-frac, frac) * FS * 60 / bpm)
        adjusted_n = max(36, int(round(FS * 60.0 / bpm)) + jitter_samples)
        t_beat = np.linspace(0, 1, adjusted_n, endpoint=False)

        # Amplitude jitter (±25 % of peak)
        amp = 1.0
        if amp_fluct > 0:
            amp = 1.0 + np.random.uniform(
                -amp_fluct / 255.0 * 0.25,
                 amp_fluct / 255.0 * 0.25,
            )

        q_  = -0.07 * amp * np.exp(-((t_beat - 0.35)**2) / (2 * 0.008**2))
        r_  =  1.00 * amp * np.exp(-((t_beat - 0.40)**2) / (2 * 0.010**2))
        s_  = -0.12 * amp * np.exp(-((t_beat - 0.46)**2) / (2 * 0.008**2))
        p_  =  0.12 * amp * np.exp(-((t_beat - 0.16)**2) / (2 * 0.025**2))
        tw_ =  0.25 * amp * np.exp(-((t_beat - 0.63)**2) / (2 * 0.050**2))
        beats.append(p_ + q_ + r_ + s_ + tw_)

    ecg_f = np.concatenate(beats)
    total = len(ecg_f)
    t_arr = np.arange(total) / FS

    # Realistic noise (same model as algo/validate_algorithm.py)
    baseline  = 0.06 * np.sin(2 * np.pi * 0.05 * t_arr)  # respiratory
    gauss     = np.random.normal(0, 0.02, total)            # thermal / quantisation
    powerline = 0.25 * np.sin(2 * np.pi * 50.0 * t_arr)    # 50 Hz mains

    ecg_noisy = ecg_f + baseline + gauss + powerline

    # Normalise → 12-bit window
    mn, mx = ecg_noisy.min(), ecg_noisy.max()
    raw_f = (ecg_noisy - mn) / max(mx - mn, 1e-9) * (DAC_OUT_HI - DAC_OUT_LO) + DAC_OUT_LO

    # DAC trace: raw signal with tiny quantisation noise (≈ ADC input before noise adds)
    dac_f = raw_f + np.random.normal(0, 4, total)

    # FIR filter with preserved initial condition (continuous — no edge artefacts)
    zi = scipy_signal.lfilter_zi(_FIR_Q15, [1.0]) * raw_f[0]
    filt_cont, _ = scipy_signal.lfilter(_FIR_Q15, [1.0], raw_f, zi=zi)

    # Normalise filtered to same window
    mn_f, mx_f = filt_cont.min(), filt_cont.max()
    filt_f = (filt_cont - mn_f) / max(mx_f - mn_f, 1e-9) * (DAC_OUT_HI - DAC_OUT_LO) + DAC_OUT_LO

    raw_12  = np.clip(raw_f,  0, 4095).astype(np.int32)
    dac_12  = np.clip(dac_f,  0, 4095).astype(np.int32)
    filt_12 = np.clip(filt_f, 0, 4095).astype(np.int32)

    # R-peak detection — same logic as pl/rpeak_detector.v
    refractory = 0
    rpeaks = np.zeros(total, dtype=bool)
    for i in range(total):
        if refractory > 0:
            refractory -= 1
        elif filt_12[i] > detect_threshold:
            rpeaks[i] = True
            refractory = REFRACTORY_SAMPLES

    # BPM from detected intervals (falls back to configured BPM if no peaks)
    peak_idx = np.where(rpeaks)[0]
    bpm_val = bpm
    if len(peak_idx) > 1:
        avg_interval = float(np.mean(np.diff(peak_idx)))
        if avg_interval > 0:
            bpm_val = int(round(21600.0 / avg_interval))

    return raw_12, dac_12, filt_12, rpeaks, bpm_val


# ---------------------------------------------------------------------------
# Per-connection stream state
# ---------------------------------------------------------------------------
class _StreamState:
    """Holds the pre-generated sample buffer for one WebSocket connection."""

    def __init__(self) -> None:
        self._raw = self._dac = self._filt = self._rpeaks = None
        self._bpm_val = 60
        self._pos     = 0
        self._snap    = {}   # snapshot of config at last refill
        self._refill()

    def _config_changed(self) -> bool:
        return any(_config[k] != self._snap.get(k) for k in _config)

    def _refill(self) -> None:
        self._snap = dict(_config)
        r, d, f, p, b = _generate_buffer(
            self._snap["bpm_ch_a"],
            self._snap["rr_fluct"],
            self._snap["amp_fluct"],
            self._snap["detect_threshold"],
        )
        self._raw, self._dac, self._filt, self._rpeaks = r, d, f, p
        self._bpm_val = b
        self._pos = 0

    def next_sample(self) -> tuple:
        if self._pos >= len(self._raw) or self._config_changed():
            self._refill()
        i = self._pos
        self._pos += 1
        return (
            int(self._raw[i]),
            int(self._dac[i]),
            int(self._filt[i]),
            bool(self._rpeaks[i]),
            self._bpm_val,
        )


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="ECG Mock Server — PYNQ-Z2 Simulator")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ConfigPayload(BaseModel):
    bpm_ch_a:         int | None = None
    rr_fluct:         int | None = None
    amp_fluct:        int | None = None
    detect_threshold: int | None = None


@app.get("/status")
async def get_status() -> dict:
    """Return current config — same shape as ps/server.py GET /status."""
    return dict(_config)


@app.post("/config")
async def post_config(payload: ConfigPayload) -> dict:
    """Accept config updates from the dashboard sliders."""
    for field, value in payload.model_dump(exclude_none=True).items():
        if field in _config:
            _config[field] = int(value)
    return {"ok": True, **_config}


@app.websocket("/ws")
async def websocket_ecg(ws: WebSocket) -> None:
    """Stream synthetic ECG at 360 Hz — same JSON schema as ps/server.py."""
    await ws.accept()
    state = _StreamState()
    t0_ms      = int(time.time() * 1000)
    sample_idx = 0

    try:
        while True:
            tick = time.monotonic()
            raw, dac, filt, rpeak, bpm = state.next_sample()
            await ws.send_json({
                "timestamp_ms": t0_ms + int(sample_idx * 1000 / FS),
                "ecg_raw":      raw,
                "ecg_dac":      dac,
                "ecg_filtered": filt,
                "bpm":          bpm,
                "rpeak":        rpeak,
                "status": {
                    "signal_present": True,
                    "lead_off":       False,
                },
            })
            sample_idx += 1
            await asyncio.sleep(max(0.0, 1.0 / FS - (time.monotonic() - tick)))
    except WebSocketDisconnect:
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=" * 55)
    print("  Mock ECG server — PYNQ-Z2 simulator")
    print("=" * 55)
    print("  WebSocket : ws://localhost:5000/ws")
    print("  Status    : http://localhost:5000/status")
    print("  Config    : POST http://localhost:5000/config")
    print()
    print("  Dashboard: set Board IP to  localhost")
    print("=" * 55)
    uvicorn.run(app, host="0.0.0.0", port=5000, log_level="warning")
