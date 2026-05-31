"""
ps/ecg_hw.py — hardware access layer for the PYNQ-Z2 ECG demo.

Framework-agnostic: loads the overlay, runs the AD7991 ADC sampler (raw MMIO
on the Xilinx AXI IIC core, the path verified in verification/), reads the AXI
register map, and builds the WebSocket packet / handles REST config + status.

Both server.py (FastAPI, for hosts that have it) and server_tornado.py (the
PYNQ-Z2 board, which is offline and only has Tornado) import from here so the
behaviour and register map stay in one place.
"""

import os
import threading
import time

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BITSTREAM_PATH = "ecg_demo.bit"
AXI_BASE = 0x43C00000
SAMPLE_RATE_HZ = 360
DEFAULT_DETECT_THRESHOLD = 2983  # 0xBA7 per algorithm_spec.md
SENTINEL_VALUES = (0xDEADBEEF, 0xFFFFFFFF)

# AD7991-0 (PMOD AD2) — read via Xilinx AXI IIC IP at 0x41600000 by raw MMIO
# (PYNQ does not bind it as axi_iic_0). Sequence verified in
# verification/capture_ecg_adc.py.
AD7991_I2C_ADDR = 0x28
AD7991_CFG_CH0  = 0x10   # enable CH0 only, Vcc reference, no filters
IIC_BASE  = 0x41600000
IIC_RANGE = 0x10000
IIC_CR    = 0x100   # Control: bit0 EN, bit1 TX_FIFO reset
IIC_SR    = 0x104   # Status:  bit6 RX_FIFO_EMPTY
IIC_TX    = 0x108   # TX_FIFO: bit9 STOP, bit8 START, [7:0] data
IIC_RX    = 0x10C   # RX_FIFO
IIC_SOFTR = 0x40    # Soft reset (write 0x0A)


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


# Map REST config field name -> (register offset, mask)
FIELD_MAP = {
    "bpm_ch_a": (ECGRegisters.BPM_CH_A, 0xFF),
    "bpm_ch_b": (ECGRegisters.BPM_CH_B, 0xFF),
    "bpm_ch_c": (ECGRegisters.BPM_CH_C, 0xFF),
    "bpm_ch_d": (ECGRegisters.BPM_CH_D, 0xFF),
    "bpm_ch_e": (ECGRegisters.BPM_CH_E, 0xFF),
    "bpm_ch_f": (ECGRegisters.BPM_CH_F, 0xFF),
    "bpm_ch_g": (ECGRegisters.BPM_CH_G, 0xFF),
    "bpm_ch_h": (ECGRegisters.BPM_CH_H, 0xFF),
    "rr_fluct":  (ECGRegisters.RR_FLUCT,  0xFF),
    "amp_fluct": (ECGRegisters.AMP_FLUCT, 0xFF),
    "detect_threshold": (ECGRegisters.DETECT_THRESHOLD, 0xFFF),
}


# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

overlay = None
axi = None
sampler = None
poller = None
start_time_ms = 0.0

# Broadcaster: one TelemetryPoller thread fills current_telemetry; every WS client
# just reads it. Keeps AXI reads O(1) regardless of client count and does R-peak
# edge detection in exactly one place (no multi-client race).
current_telemetry: dict = {}
telemetry_lock = threading.Lock()


# ---------------------------------------------------------------------------
# AXI helpers
# ---------------------------------------------------------------------------

def axi_read(offset: int) -> int:
    value = axi.read(offset)
    if value in SENTINEL_VALUES:
        print(f"WARNING: axi_read(0x{offset:02X}) returned 0x{value:08X} — PL connectivity issue?")
    return value


def axi_write(offset: int, value: int) -> None:
    axi.write(offset, value)


# ---------------------------------------------------------------------------
# AD7991 sampler (raw MMIO over the AXI IIC core)
# ---------------------------------------------------------------------------

class AD7991Sampler:
    """Background thread that reads AD7991-0 CH0 via raw MMIO and writes each
    12-bit sample to ECG_RAW (0x28). Writing ECG_RAW also pulses adc_valid into
    the FIR. The per-transaction soft-reset + brief settles are required for
    reliable back-to-back reads (verified to sustain ~360 Hz)."""

    def __init__(self, iic_mmio, axi_ctrl):
        self._iic = iic_mmio
        self._axi_ctrl = axi_ctrl
        self._stop_evt = threading.Event()
        self._thread = None
        self._error_logged = False

    def start(self) -> None:
        self._stop_evt.clear()
        self._thread = threading.Thread(target=self._loop, name="AD7991Sampler", daemon=True)
        self._thread.start()
        print(f"AD7991Sampler started at {SAMPLE_RATE_HZ} Hz via raw MMIO "
              f"(IIC 0x{IIC_BASE:08X}, slave 0x{AD7991_I2C_ADDR:02X}, cfg 0x{AD7991_CFG_CH0:02X})")

    def stop(self) -> None:
        self._stop_evt.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        print("AD7991Sampler stopped.")

    def _read_ch0(self):
        iic = self._iic
        iic.write(IIC_SOFTR, 0x0A)
        time.sleep(0.001)
        iic.write(IIC_CR, 0x02)
        iic.write(IIC_CR, 0x01)
        iic.write(IIC_TX, 0x100 | (AD7991_I2C_ADDR << 1))      # START + addr(W)
        iic.write(IIC_TX, 0x200 | AD7991_CFG_CH0)              # STOP  + config
        time.sleep(0.001)
        iic.write(IIC_TX, 0x100 | (AD7991_I2C_ADDR << 1) | 1)  # START + addr(R)
        iic.write(IIC_TX, 0x200 | 0x02)                        # STOP  + read 2
        deadline = time.time() + 0.05
        b = []
        while len(b) < 2 and time.time() < deadline:
            if not (iic.read(IIC_SR) & 0x40):
                b.append(iic.read(IIC_RX) & 0xFF)
        if len(b) < 2:
            return None
        return ((b[0] & 0x0F) << 8) | b[1]

    def _loop(self) -> None:
        period_s = 1.0 / SAMPLE_RATE_HZ
        next_tick = time.monotonic()
        while not self._stop_evt.is_set():
            try:
                raw = self._read_ch0()
                if raw is not None:
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
                next_tick = time.monotonic()


# ---------------------------------------------------------------------------
# Telemetry broadcaster (single poller thread feeding all WS clients)
# ---------------------------------------------------------------------------

class TelemetryPoller:
    """Single background thread that reads the AXI register map once per tick,
    does R-peak edge detection in one place, and publishes the latest packet to
    `current_telemetry`. WS clients read that via get_telemetry() — so hardware
    reads are O(1) regardless of client count, and every client observes the same
    R-peak edges (fixes the multi-client R-peak race)."""

    def __init__(self):
        self._stop_evt = threading.Event()
        self._thread = None
        self._prev_rpeak = 0
        self._error_logged = False

    def start(self) -> None:
        self._prev_rpeak = axi_read(ECGRegisters.RPEAK_COUNT) & 0xFFFF
        self._stop_evt.clear()
        self._thread = threading.Thread(target=self._loop, name="TelemetryPoller", daemon=True)
        self._thread.start()
        print(f"TelemetryPoller started at {SAMPLE_RATE_HZ} Hz (broadcaster)")

    def stop(self) -> None:
        self._stop_evt.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        print("TelemetryPoller stopped.")

    def _loop(self) -> None:
        global current_telemetry
        period_s = 1.0 / SAMPLE_RATE_HZ
        next_tick = time.monotonic()
        while not self._stop_evt.is_set():
            try:
                now_ms       = time.monotonic() * 1000 - start_time_ms
                ecg_raw      = axi_read(ECGRegisters.ECG_RAW)      & 0xFFF
                ecg_dac      = axi_read(ECGRegisters.ECG_DAC)      & 0xFFF
                ecg_filtered = axi_read(ECGRegisters.ECG_FILTERED) & 0xFFF
                bpm_out      = axi_read(ECGRegisters.BPM_OUT)      & 0xFF
                rpeak_count  = axi_read(ECGRegisters.RPEAK_COUNT)  & 0xFFFF
                status_reg   = axi_read(ECGRegisters.STATUS)       & 0x03

                rpeak_fired = rpeak_count != self._prev_rpeak
                self._prev_rpeak = rpeak_count

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
                with telemetry_lock:
                    current_telemetry = packet
            except Exception as exc:
                if not self._error_logged:
                    print(f"Telemetry poll error (suppressing further): {exc}")
                    self._error_logged = True
            next_tick += period_s
            delta = next_tick - time.monotonic()
            if delta > 0:
                time.sleep(delta)
            else:
                next_tick = time.monotonic()


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

def load_overlay() -> None:
    """Load the PL bitstream, start the ADC sampler + telemetry poller."""
    global overlay, axi, sampler, poller, start_time_ms

    if not os.path.exists(BITSTREAM_PATH):
        print(f"ERROR: {BITSTREAM_PATH} not found. Copy the Vivado bitstream first.")
        raise SystemExit(1)

    from pynq import Overlay, MMIO  # imported here so unit tests can mock

    overlay = Overlay(BITSTREAM_PATH)
    # Access the custom control block by address via raw MMIO (PYNQ binds the
    # instance as ecg_process_top_0, not axi_ecg_ctrl; MMIO is name-independent
    # and is the path verified in verification/verify_dac_adc.py).
    axi = MMIO(AXI_BASE, 0x1000)
    axi_write(ECGRegisters.DETECT_THRESHOLD, DEFAULT_DETECT_THRESHOLD)
    print(f"Overlay loaded. DETECT_THRESHOLD set to {DEFAULT_DETECT_THRESHOLD} (0x{DEFAULT_DETECT_THRESHOLD:03X}).")

    iic_mmio = MMIO(IIC_BASE, IIC_RANGE)
    sampler = AD7991Sampler(iic_mmio, axi)
    sampler.start()

    start_time_ms = time.monotonic() * 1000
    poller = TelemetryPoller()   # must start after start_time_ms is set
    poller.start()


def shutdown() -> None:
    """Stop the poller + sampler and release the overlay."""
    global sampler, poller, overlay
    if poller is not None:
        try:
            poller.stop()
        except Exception:
            pass
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
# Data plane — packet / config / status (shared by both transports)
# ---------------------------------------------------------------------------

def get_telemetry() -> dict:
    """Return a copy of the latest broadcaster packet (matches ws_schema.json).
    WS clients call this — it performs NO AXI reads, so hardware load is constant
    regardless of how many clients are connected."""
    with telemetry_lock:
        return dict(current_telemetry)


def apply_config(data: dict) -> list:
    """Write any supplied config fields (validated/clamped). Returns names written."""
    written = []
    for name, (offset, mask) in FIELD_MAP.items():
        if name not in data or data[name] is None:
            continue
        try:
            value = int(data[name])
        except (TypeError, ValueError):
            continue
        axi_write(offset, value & mask)
        written.append(name)
    return written


def get_status() -> dict:
    status_reg = axi_read(ECGRegisters.STATUS) & 0x03
    return {
        "bpm_ch_a":         axi_read(ECGRegisters.BPM_CH_A)         & 0xFF,
        "rr_fluct":         axi_read(ECGRegisters.RR_FLUCT)         & 0xFF,
        "amp_fluct":        axi_read(ECGRegisters.AMP_FLUCT)        & 0xFF,
        "detect_threshold": axi_read(ECGRegisters.DETECT_THRESHOLD) & 0xFFF,
        "bpm_out":          axi_read(ECGRegisters.BPM_OUT)          & 0xFF,
        "signal_present":   bool(status_reg & 0x01),
    }
