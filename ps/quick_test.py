"""
Quick hardware verification for ECG demo bitstream.
Run on PYNQ-Z2 board after loading ecg_demo.bit.

Checks:
  - ECG_DAC (0x40) cycles through ROM values (not stuck at 0x800)
  - ECG_RAW (0x28) reads non-zero ADC samples via loopback
  - Saves waveform plot to /home/xilinx/ecg_quick_test.png

Usage (on board):
  sudo python3 quick_test.py
"""

import time
import sys

try:
    import pynq
    from pynq import Overlay, MMIO
    PYNQ_AVAILABLE = True
except ImportError:
    PYNQ_AVAILABLE = False
    print("WARNING: pynq not found — using mmio stub for offline testing")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE_ADDR   = 0x43C00000
MAP_SIZE    = 0x44         # covers all registers up to 0x40

REG_ECG_RAW    = 0x28
REG_ECG_FILT   = 0x2C
REG_BPM_OUT    = 0x30
REG_STATUS     = 0x3C
REG_ECG_DAC    = 0x40

N_SAMPLES  = 360           # one cardiac cycle at 60 BPM
SLEEP_S    = 1.0 / 360     # ~2.78 ms between samples
OUT_PNG    = "/home/xilinx/ecg_quick_test.png"


def main():
    print("=== ECG Demo Quick Test ===")

    if not PYNQ_AVAILABLE:
        print("PYNQ not available. Cannot run on this machine.")
        sys.exit(1)

    print("Loading overlay ...")
    ol = Overlay("/home/xilinx/pynq-ecg-demo/ps/ecg_demo.bit")
    print("  Overlay loaded OK")

    mmio = MMIO(BASE_ADDR, MAP_SIZE)

    # Write detect threshold per algorithm_spec (default reset is 0x800, should be 2983)
    mmio.write(0x38, 2983)
    print(f"  DETECT_THRESHOLD set to 2983 (0x{2983:03X})")

    dac_vals  = []
    raw_vals  = []
    filt_vals = []

    print(f"Sampling {N_SAMPLES} points at ~360 Hz ...")
    for i in range(N_SAMPLES):
        dac_vals.append(mmio.read(REG_ECG_DAC) & 0xFFF)
        raw_vals.append(mmio.read(REG_ECG_RAW) & 0xFFF)
        filt_vals.append(mmio.read(REG_ECG_FILT) & 0xFFF)
        time.sleep(SLEEP_S)

    bpm_out = mmio.read(REG_BPM_OUT) & 0xFF
    status  = mmio.read(REG_STATUS) & 0x3

    print(f"\n--- Results ---")
    print(f"  BPM_OUT    : {bpm_out}")
    print(f"  STATUS     : 0b{status:02b}  (signal_present={status & 1})")
    print(f"  ECG_DAC    : min={min(dac_vals):#05x}  max={max(dac_vals):#05x}  "
          f"range={max(dac_vals)-min(dac_vals)}")
    print(f"  ECG_RAW    : min={min(raw_vals):#05x}  max={max(raw_vals):#05x}  "
          f"range={max(raw_vals)-min(raw_vals)}")

    # Pass/fail
    dac_range = max(dac_vals) - min(dac_vals)
    raw_range = max(raw_vals) - min(raw_vals)

    print()
    if dac_range < 10:
        print("FAIL: ECG_DAC is flat — DDS still frozen (bitstream may not include fix)")
    else:
        print(f"PASS: ECG_DAC varies by {dac_range} counts — DDS is advancing through ROM")

    if raw_range < 10:
        print("WARN: ECG_RAW is flat — check ADC loopback wiring (PMOD AD2 on JB)")
    else:
        print(f"PASS: ECG_RAW varies by {raw_range} counts — ADC loopback active")

    # Plot
    t = [i * SLEEP_S * 1000 for i in range(N_SAMPLES)]  # ms

    fig, axes = plt.subplots(3, 1, figsize=(10, 8), sharex=True)
    fig.suptitle("ECG Demo — Quick Verification")

    axes[0].plot(t, dac_vals, color="steelblue", linewidth=0.8)
    axes[0].set_ylabel("ECG_DAC (counts)")
    axes[0].set_title("DAC waveform (DDS ROM output)")

    axes[1].plot(t, raw_vals, color="darkorange", linewidth=0.8)
    axes[1].set_ylabel("ECG_RAW (counts)")
    axes[1].set_title("ADC raw (loopback from DAC)")

    axes[2].plot(t, filt_vals, color="seagreen", linewidth=0.8)
    axes[2].set_ylabel("ECG_FILTERED (counts)")
    axes[2].set_title("FIR-filtered signal")
    axes[2].set_xlabel("Time (ms)")

    plt.tight_layout()
    plt.savefig(OUT_PNG, dpi=120)
    print(f"\nPlot saved: {OUT_PNG}")


if __name__ == "__main__":
    main()
