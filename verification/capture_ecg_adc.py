# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
capture_ecg_adc.py -- subsystem verification: capture an ECG time series straight
from the AD7991-0 ADC and save PNG + CSV. Proves the full analog datapath
(DDS ROM -> DAC -> loopback wire -> ADC CH0 -> I2C -> PS). Needs a loopback wire
from a DAC channel output to AD2 CH0.

Run ON THE BOARD as root:
    sudo bash -c 'source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; \
        python3 verification/capture_ecg_adc.py'

Output: /home/xilinx/ecg_adc.png + /home/xilinx/ecg_adc.csv
        (pull the CSV to the PC and re-plot with verification/plot_ecg_csv.py)
"""

import os
import sys
import time
from pynq import Overlay, MMIO

I2C_ADDR = 0x28
CFG_CH0  = 0x10
IIC_BASE = 0x41600000
CR, SR, TX, RX, SOFTR = 0x100, 0x104, 0x108, 0x10C, 0x40

CAPTURE_S = 6.0          # seconds of ECG to record
OUT_PNG   = "/home/xilinx/ecg_adc.png"
OUT_CSV   = "/home/xilinx/ecg_adc.csv"


def find_bitstream():
    cands = []
    if os.environ.get("ECG_BIT"):
        cands.append(os.environ["ECG_BIT"])
    here = os.path.dirname(os.path.abspath(__file__))
    cands += [
        os.path.join(here, "ecg_demo.bit"),
        os.path.join(here, "..", "ps", "ecg_demo.bit"),
        "/home/xilinx/jupyter_notebooks/pynq-ecg-demo/ps/ecg_demo.bit",
    ]
    for c in cands:
        if os.path.exists(c):
            return os.path.abspath(c)
    raise FileNotFoundError("ecg_demo.bit not found; tried:\n  " + "\n  ".join(cands))


def read_ch0(iic):
    """One AD7991 CH0 read via AXI-IIC dynamic mode. Returns 12-bit int or None.
    The core needs a soft reset + brief settle before every transaction -- this
    exact pattern is what makes back-to-back sampling reliable."""
    iic.write(SOFTR, 0x0A); time.sleep(0.001)
    iic.write(CR, 0x02)                        # reset TX FIFO
    iic.write(CR, 0x01)                        # enable
    iic.write(TX, 0x100 | (I2C_ADDR << 1))     # START + addr(W)
    iic.write(TX, 0x200 | CFG_CH0)             # STOP  + config
    time.sleep(0.001)
    iic.write(TX, 0x100 | (I2C_ADDR << 1) | 1) # START + addr(R)
    iic.write(TX, 0x200 | 0x02)                # STOP  + read 2 bytes
    deadline = time.time() + 0.05
    b = []
    while len(b) < 2 and time.time() < deadline:
        if not (iic.read(SR) & 0x40):          # RX_FIFO not empty
            b.append(iic.read(RX) & 0xFF)
    if len(b) < 2:
        return None
    return ((b[0] & 0x0F) << 8) | b[1]


def main():
    bit = find_bitstream()
    print("Loading overlay:", bit)
    ol = Overlay(bit)
    iic = MMIO(IIC_BASE, 0x10000)

    print("Capturing %.1f s from AD7991 CH0 ..." % CAPTURE_S)
    t0 = time.time()
    ts, vals = [], []
    misses = 0
    while time.time() - t0 < CAPTURE_S:
        v = read_ch0(iic)
        if v is None:
            misses += 1
            continue
        ts.append(time.time() - t0)
        vals.append(v)

    n = len(vals)
    if n == 0:
        print("[FAIL] no samples captured"); sys.exit(1)
    rate = n / (ts[-1] if ts[-1] > 0 else 1)
    mn, mx = min(vals), max(vals)
    print("  samples=%d  rate~%.0f Hz  misses=%d" % (n, rate, misses))
    print("  raw: min=%d max=%d range=%d  (%.3f..%.3f V)" %
          (mn, mx, mx - mn, mn * 3.3 / 4096, mx * 3.3 / 4096))

    with open(OUT_CSV, "w") as f:
        f.write("t_s,raw_counts,volts\n")
        for t, v in zip(ts, vals):
            f.write("%.4f,%d,%.4f\n" % (t, v, v * 3.3 / 4096))
    print("  CSV saved:", OUT_CSV)

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(11, 4))
        ax.plot(ts, [v * 3.3 / 4096 for v in vals], color="crimson", linewidth=0.8)
        ax.set_title("ECG captured from AD7991 ADC (CH0, loopback from DAC)")
        ax.set_xlabel("Time (s)"); ax.set_ylabel("ADC voltage (V)")
        ax.grid(True, alpha=0.3)
        fig.tight_layout(); fig.savefig(OUT_PNG, dpi=120)
        print("  PNG saved:", OUT_PNG)
    except Exception as e:
        print("  [warn] plot failed (%s); CSV still available" % e)


if __name__ == "__main__":
    main()
