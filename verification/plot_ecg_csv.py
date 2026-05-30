# -*- coding: utf-8 -*-
"""Re-plot an ECG CSV captured from the ADC (columns: t_s,raw_counts,volts).
PC-side helper -- needs matplotlib locally.

Usage:  py verification/plot_ecg_csv.py [path/to/ecg_adc.csv]
Output: <csv>.png next to the CSV, with an auto beat-count / BPM estimate.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path = sys.argv[1] if len(sys.argv) > 1 else "captures/ecg_adc.csv"
out_png = os.path.splitext(csv_path)[0] + ".png"

t, volts = [], []
with open(csv_path, newline="") as f:
    for row in csv.DictReader(f):
        t.append(float(row["t_s"]))
        volts.append(float(row["volts"]))

# crude heart-rate estimate: count QRS upstrokes crossing a high threshold
thr = min(volts) + 0.6 * (max(volts) - min(volts))
beats, above = 0, False
for v in volts:
    if v > thr and not above:
        beats += 1; above = True
    elif v < thr:
        above = False
dur = t[-1] - t[0] if len(t) > 1 else 1.0
bpm = beats / dur * 60.0

fig, ax = plt.subplots(figsize=(12, 4))
ax.plot(t, volts, color="crimson", linewidth=0.9)
ax.set_title("ECG from AD7991 ADC  -  %d beats / %.1fs  ~%.0f BPM  (n=%d, ~%.0f Hz)"
             % (beats, dur, bpm, len(t), len(t) / dur))
ax.set_xlabel("Time (s)")
ax.set_ylabel("ADC voltage (V)")
ax.grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig(out_png, dpi=130)
print("wrote", out_png, "| beats=%d ~%.0f BPM | V %.3f..%.3f"
      % (beats, bpm, min(volts), max(volts)))
