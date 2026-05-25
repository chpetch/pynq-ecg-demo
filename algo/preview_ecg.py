import numpy as np
import matplotlib.pyplot as plt
import neurokit2 as nk
import os

FS = 360
DURATION = 10

ecg_clean = nk.ecg_simulate(duration=DURATION, sampling_rate=FS, heart_rate=60, noise=0)

t = np.linspace(0, DURATION, len(ecg_clean))
baseline = 0.05 * np.max(ecg_clean) * np.sin(2 * np.pi * 0.05 * t)
noise = np.random.normal(0, 0.02 * np.max(ecg_clean), len(ecg_clean))
ecg_noisy = ecg_clean + baseline + noise

# Scale to 12-bit unsigned (0-4095)
ecg_min, ecg_max = ecg_noisy.min(), ecg_noisy.max()
ecg_12bit = ((ecg_noisy - ecg_min) / (ecg_max - ecg_min) * 4095).astype(int)

peaks, _ = nk.ecg_peaks(ecg_clean, sampling_rate=FS)
peak_idx = np.where(peaks["ECG_R_Peaks"] == 1)[0]

os.makedirs("algo/plots", exist_ok=True)

fig, axes = plt.subplots(2, 1, figsize=(14, 7))
fig.suptitle("PYNQ-Z2 ECG Demo — Signal Preview (360 Hz, 60 BPM)", fontsize=13)

axes[0].plot(t, ecg_noisy, color="#2196F3", linewidth=0.8, label="Noisy ECG (analog)")
axes[0].plot(t[peak_idx], ecg_noisy[peak_idx], "rv", markersize=7, label=f"R-peaks ({len(peak_idx)} detected)")
axes[0].set_ylabel("Amplitude (normalised)")
axes[0].set_title("Floating-point signal (with baseline wander + gaussian noise)")
axes[0].legend(loc="upper right")
axes[0].set_xlim(0, DURATION)
axes[0].grid(True, alpha=0.3)

axes[1].plot(t, ecg_12bit, color="#4CAF50", linewidth=0.8, label="12-bit DAC output")
axes[1].plot(t[peak_idx], ecg_12bit[peak_idx], "rv", markersize=7)
axes[1].set_ylabel("DAC value (0–4095)")
axes[1].set_xlabel("Time (s)")
axes[1].set_title("12-bit scaled signal — what the PmodDA4 will output")
axes[1].set_ylim(0, 4095)
axes[1].set_xlim(0, DURATION)
axes[1].grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig("algo/plots/ecg_preview.png", dpi=150, bbox_inches="tight")
plt.close()

print(f"Sample rate  : {FS} Hz")
print(f"Duration     : {DURATION} s  ({len(ecg_12bit)} samples)")
print(f"R-peaks      : {len(peak_idx)} detected (~{len(peak_idx)/DURATION*60:.0f} BPM)")
print(f"12-bit range : {ecg_12bit.min()} – {ecg_12bit.max()}")
print(f"Plot saved   : algo/plots/ecg_preview.png")
