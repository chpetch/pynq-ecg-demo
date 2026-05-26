"""
validate_algorithm.py
=====================
ECG DSP algorithm validation for PYNQ-Z2 ECG Demo -- Milestone 2.

Sections:
  1. Generate synthetic ECG (neurokit2, 360 Hz, 10 s, baseline wander + gaussian + powerline noise)
  2. Design 31-tap FIR bandpass filter (scipy, 0.5-40 Hz, Hamming window)
  3. Print float and Q1.15 integer coefficients
  4. Simulate Q1.15 fixed-point filter (integer arithmetic, 32-bit accumulator,
     truncate bits [26:15] -> 12-bit output)
  5. Pan-Tompkins simplified R-peak detector (threshold = 0.70 * max, refractory = 72)
  6. Assert SNR gain > 10 dB and detection rate > 95%
  7. Save 3 plots to algo/plots/
  8. Print summary block
"""

import os
import sys
import numpy as np
from scipy import signal
import matplotlib
matplotlib.use("Agg")  # non-interactive backend -- no display required
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLOTS_DIR = os.path.join(SCRIPT_DIR, "plots")
os.makedirs(PLOTS_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
FS = 360          # sample rate (Hz)
DURATION = 10     # seconds
N_TAPS = 31       # FIR filter taps (must be odd)
F_LOW = 0.5       # passband low (Hz)
F_HIGH = 40.0     # passband high (Hz)
HEART_RATE = 60   # BPM for synthetic ECG
Q_SCALE = 32768   # Q1.15 scale factor (2^15)
ACC_BITS = 32     # accumulator width
OUT_SHIFT = 15    # right-shift to extract output (bits [26:15] -> shift 15)
OUT_MASK = 0xFFF  # 12-bit output mask
REFRACTORY = 72   # samples (200 ms @ 360 Hz)
THRESHOLD_FACTOR = 0.70  # fraction of max filtered signal

# Noise model (clinically realistic unconditioned ECG):
BASELINE_WANDER_AMP = 0.10   # 10% of peak, at 0.05 Hz
GAUSSIAN_SIGMA = 0.02         # 2% sigma wideband noise
POWERLINE_AMP = 0.40          # 40% amplitude, 50 Hz powerline EMI (out of passband)

# ---------------------------------------------------------------------------
# 1. Generate synthetic ECG
# ---------------------------------------------------------------------------
print("Generating synthetic ECG ...")
try:
    import neurokit2 as nk
    ecg_float = nk.ecg_simulate(
        duration=DURATION,
        sampling_rate=FS,
        heart_rate=HEART_RATE,
        noise=0.0,        # we add noise manually
        random_state=42,
    )
    ecg_float = np.array(ecg_float, dtype=np.float64)
except Exception as exc:
    print(f"neurokit2 failed ({exc}), falling back to numpy ECG model")
    t = np.linspace(0, DURATION, DURATION * FS, endpoint=False)
    period = int(FS * 60.0 / HEART_RATE)
    ecg_float = np.zeros(len(t))
    for beat_start in range(0, len(t), period):
        for offset, amp, width in [
            (int(-0.1 * period), 0.1, 0.015),
            (0, 1.0, 0.008),
            (int(0.1 * period), -0.3, 0.015),
        ]:
            idx = beat_start + offset
            if 0 <= idx < len(t):
                ecg_float += amp * np.exp(
                    -((np.arange(len(t)) - idx) ** 2) / (2 * (width * FS) ** 2)
                )

# Normalize to [0..1]
ecg_min, ecg_max = ecg_float.min(), ecg_float.max()
ecg_norm = (ecg_float - ecg_min) / (ecg_max - ecg_min)

# Add noise sources (all amplitudes relative to normalised unit-peak signal)
t_arr = np.arange(len(ecg_norm)) / FS
rng = np.random.default_rng(42)

# 1. Baseline wander: 0.05 Hz sinusoid (DC-like drift, below passband)
baseline_wander = BASELINE_WANDER_AMP * np.sin(2 * np.pi * 0.05 * t_arr)
# 2. Wideband gaussian noise (EMG-like broadband interference)
gaussian_noise = rng.normal(0, GAUSSIAN_SIGMA, size=len(ecg_norm))
# 3. Powerline interference: 50 Hz sinusoid (above 40 Hz passband cutoff)
powerline_noise = POWERLINE_AMP * np.sin(2 * np.pi * 50.0 * t_arr)

total_noise = baseline_wander + gaussian_noise + powerline_noise
ecg_noisy = ecg_norm + total_noise

# Scale to 12-bit unsigned ADC range (0..4095)
ecg_noisy_12 = ecg_noisy * 4095.0
ecg_clean_12 = ecg_norm * 4095.0

print(f"  ECG samples : {len(ecg_norm)}  ({DURATION} s @ {FS} Hz)")
print(f"  Noise added : BW({BASELINE_WANDER_AMP*100:.0f}%@0.05Hz) + gaussian(sigma={GAUSSIAN_SIGMA*100:.0f}%) + powerline({POWERLINE_AMP*100:.0f}%@50Hz)")

# ---------------------------------------------------------------------------
# 2. Design 31-tap FIR bandpass filter
# ---------------------------------------------------------------------------
print("\nDesigning FIR bandpass filter ...")

# firwin with bandpass: pass [F_LOW, F_HIGH], Hamming window
fir_coeffs_float = signal.firwin(
    numtaps=N_TAPS,
    cutoff=[F_LOW, F_HIGH],
    window="hamming",
    pass_zero=False,   # bandpass
    fs=FS,
)

print(f"\n  Float coefficients (h[0]..h[{N_TAPS-1}]):")
for i, c in enumerate(fir_coeffs_float):
    print(f"    h[{i:2d}] = {c:+.10f}")

# Convert to Q1.15
fir_coeffs_q15 = np.clip(
    np.round(fir_coeffs_float * Q_SCALE).astype(np.int32),
    -32768, 32767
)

print(f"\n  Q1.15 integer coefficients:")
for i, c in enumerate(fir_coeffs_q15):
    print(f"    h[{i:2d}] = {c:6d}")

# ---------------------------------------------------------------------------
# 3. Apply floating-point filter (reference)
# ---------------------------------------------------------------------------
print("\nApplying floating-point FIR filter ...")
ecg_filtered_float = signal.lfilter(fir_coeffs_float, 1.0, ecg_noisy_12)

# Also filter the clean signal to get the ideal bandpass output
ecg_clean_filtered = signal.lfilter(fir_coeffs_float, 1.0, ecg_clean_12)

# Filter delay (linear phase FIR: exactly (N_TAPS-1)/2 samples)
delay = (N_TAPS - 1) // 2

# ---------------------------------------------------------------------------
# 4. Fixed-point Q1.15 filter simulation
# ---------------------------------------------------------------------------
print("Simulating Q1.15 fixed-point filter ...")

def fir_fixed_point(samples_float, coeffs_q15):
    """
    Simulate a 31-tap FIR filter with Q1.15 coefficients.

    Data path:
      - Input: 12-bit unsigned integer (0..4095), zero-extended to 16-bit
      - Coefficient: 16-bit signed Q1.15
      - Product: 16 * 12 = 28-bit, sign-extended to 32-bit
      - Accumulator: 32-bit signed, summed across 31 taps
      - Output truncation: accumulator >> 15, then keep lower 12 bits
        (equivalent to bits [26:15] of the 32-bit accumulator)

    Returns array of 12-bit integers (unsigned, range 0..4095).
    """
    n_taps = len(coeffs_q15)
    samples_int = np.round(samples_float).astype(np.int32)
    output = np.zeros(len(samples_int), dtype=np.int32)

    for n in range(len(samples_int)):
        acc = np.int64(0)
        for k in range(n_taps):
            if n - k >= 0:
                product = np.int64(samples_int[n - k]) * np.int64(coeffs_q15[k])
                acc += product
        # Clip to 32-bit signed
        acc32 = int(np.clip(int(acc), -(2**31), 2**31 - 1))
        # Right shift by 15 to align Q1.15 product, keep 12-bit result
        shifted = acc32 >> OUT_SHIFT
        output[n] = shifted & OUT_MASK

    return output

print("  (running fixed-point simulation on full signal -- may take a moment)")
ecg_fp = fir_fixed_point(ecg_noisy_12, fir_coeffs_q15)

# ---------------------------------------------------------------------------
# SNR computation
# ---------------------------------------------------------------------------
# SNR is measured using the bandpass-filtered clean ECG as the signal reference.
# This correctly attributes noise as the distortion introduced by the noise sources,
# not as distortion from the filter's own shaping of the ECG waveform.
#
# SNR_raw     = signal_power / noise_power_before_filter
# SNR_filtered = signal_power / noise_power_after_filter
#
# where noise_power_before = power of (noisy - clean) at filter input
#       noise_power_after  = power of (filtered_noisy - filtered_clean) at filter output
# This directly measures how much noise power the filter rejected.

clean_ref = ecg_clean_filtered[delay:]
noise_before_12 = total_noise[delay:] * 4095.0          # noise at filter input
noise_after_12 = (ecg_filtered_float - ecg_clean_filtered)[delay:]  # residual noise at output

snr_raw = 10 * np.log10(np.mean(clean_ref ** 2) / np.mean(noise_before_12 ** 2))
snr_filtered = 10 * np.log10(np.mean(clean_ref ** 2) / np.mean(noise_after_12 ** 2))
snr_gain = snr_filtered - snr_raw

print(f"\n  SNR raw signal  : {snr_raw:.1f} dB")
print(f"  SNR filtered    : {snr_filtered:.1f} dB")
print(f"  SNR gain        : {snr_gain:.1f} dB")

# ---------------------------------------------------------------------------
# 5. Pan-Tompkins simplified R-peak detector
# ---------------------------------------------------------------------------
print("\nRunning R-peak detector ...")

# Use float-filtered signal shifted to compensate for filter delay
filtered_for_detection = ecg_filtered_float[delay:]

# Threshold: THRESHOLD_FACTOR * max of filtered signal
detection_threshold = THRESHOLD_FACTOR * filtered_for_detection.max()
print(f"  Detection threshold (float) : {detection_threshold:.2f}")

# Threshold in 12-bit domain: fixed-point output values are in the same
# numeric range as the float output (both relative to 12-bit ADC scale).
threshold_12bit = int(round(detection_threshold))
print(f"  Detection threshold (12-bit): {threshold_12bit}")

# Detect peaks with refractory period (Pan-Tompkins simplified)
detected_peaks = []
refractory_count = 0

for i in range(len(filtered_for_detection)):
    if refractory_count > 0:
        refractory_count -= 1
        continue
    if filtered_for_detection[i] > detection_threshold:
        detected_peaks.append(i)
        refractory_count = REFRACTORY

detected_peaks = np.array(detected_peaks)
print(f"  Detected {len(detected_peaks)} peaks")

# Ground truth peaks from neurokit2 or local-maxima fallback
try:
    import neurokit2 as nk
    _, rpeaks_info = nk.ecg_peaks(ecg_norm, sampling_rate=FS)
    true_peaks = rpeaks_info["ECG_R_Peaks"]
    true_peaks_adj = true_peaks[true_peaks >= delay] - delay
except Exception:
    from scipy.signal import find_peaks as _find_peaks
    true_peaks_arr, _ = _find_peaks(
        ecg_clean_12[delay:],
        height=0.5 * ecg_clean_12.max(),
        distance=REFRACTORY,
    )
    true_peaks_adj = true_peaks_arr

print(f"  Ground truth peaks: {len(true_peaks_adj)}")

# Match detected peaks to ground truth (within +-36 samples = 100 ms tolerance)
TOLERANCE = 36
matched = 0
for tp in true_peaks_adj:
    if len(detected_peaks) == 0:
        break
    diffs = np.abs(detected_peaks - tp)
    if diffs.min() <= TOLERANCE:
        matched += 1

detection_rate = (matched / len(true_peaks_adj)) * 100.0 if len(true_peaks_adj) > 0 else 0.0
print(f"  Matched: {matched} / {len(true_peaks_adj)} ({detection_rate:.1f}%)")

# BPM from R-R intervals
if len(detected_peaks) >= 2:
    intervals = np.diff(detected_peaks)
    bpm_per_beat = (FS * 60.0) / intervals
    bpm_mean = bpm_per_beat.mean()
    bpm_error = abs(bpm_mean - HEART_RATE)
else:
    bpm_per_beat = np.array([])
    bpm_mean = 0.0
    bpm_error = float("nan")

print(f"  BPM mean: {bpm_mean:.1f}, error vs {HEART_RATE} BPM: {bpm_error:.1f} BPM")

# ---------------------------------------------------------------------------
# 6. Assertions
# ---------------------------------------------------------------------------
print("\nRunning assertions ...")
assert snr_gain > 10.0, (
    f"SNR gain assertion FAILED: {snr_gain:.1f} dB <= 10.0 dB"
)
assert detection_rate > 95.0, (
    f"Detection rate assertion FAILED: {detection_rate:.1f}% <= 95.0%"
)
print("  Both assertions PASSED.")

# ---------------------------------------------------------------------------
# 7. Plots
# ---------------------------------------------------------------------------
print("\nSaving plots ...")

# --- Plot 1: Filter frequency response ---
nyq = FS / 2.0
w, H = signal.freqz(fir_coeffs_float, worN=8192, fs=FS)
fig, ax = plt.subplots(figsize=(8, 4))
ax.plot(w, 20 * np.log10(np.abs(H) + 1e-12), color="steelblue")
ax.axvline(F_LOW, color="red", linestyle="--", label=f"F_low = {F_LOW} Hz")
ax.axvline(F_HIGH, color="orange", linestyle="--", label=f"F_high = {F_HIGH} Hz")
ax.axvline(50.0, color="purple", linestyle=":", linewidth=0.8, label="50 Hz powerline")
ax.set_xlabel("Frequency (Hz)")
ax.set_ylabel("Magnitude (dB)")
ax.set_title(f"31-tap FIR Bandpass Filter Response (0.5-40 Hz, Hamming, fs={FS} Hz)")
ax.set_xlim(0, nyq)
ax.set_ylim(-80, 5)
ax.grid(True, alpha=0.4)
ax.legend()
fig.tight_layout()
fig.savefig(os.path.join(PLOTS_DIR, "filter_response.png"), dpi=150)
plt.close(fig)
print("  Saved filter_response.png")

# --- Plot 2: Raw vs filtered ECG (5 seconds) ---
t_plot = np.arange(5 * FS) / FS
idx_end = min(5 * FS, len(ecg_noisy_12), len(ecg_filtered_float))
fig, axes = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
axes[0].plot(t_plot[:idx_end], ecg_noisy_12[:idx_end], color="gray", linewidth=0.7,
             label="Noisy ECG (raw)")
axes[0].plot(t_plot[:idx_end], ecg_clean_12[:idx_end], color="green", linewidth=0.8,
             alpha=0.7, label="Clean ECG (reference)")
axes[0].set_ylabel("ADC counts (12-bit)")
axes[0].set_title("Raw vs Filtered ECG (first 5 s)")
axes[0].legend(loc="upper right", fontsize=8)
axes[0].grid(True, alpha=0.3)
axes[1].plot(t_plot[:idx_end], ecg_filtered_float[:idx_end], color="steelblue", linewidth=0.8,
             label=f"Filtered (float FIR, SNR gain={snr_gain:.1f} dB)")
axes[1].set_xlabel("Time (s)")
axes[1].set_ylabel("ADC counts (12-bit)")
axes[1].legend(loc="upper right", fontsize=8)
axes[1].grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig(os.path.join(PLOTS_DIR, "ecg_comparison.png"), dpi=150)
plt.close(fig)
print("  Saved ecg_comparison.png")

# --- Plot 3: R-peak detection ---
t_detect = np.arange(len(filtered_for_detection)) / FS
fig, ax = plt.subplots(figsize=(12, 4))
ax.plot(t_detect, filtered_for_detection, color="steelblue", linewidth=0.7,
        label="Filtered ECG")
if len(detected_peaks) > 0:
    ax.scatter(
        detected_peaks / FS,
        filtered_for_detection[detected_peaks],
        color="red", s=40, zorder=5,
        label=f"Detected R-peaks (n={len(detected_peaks)}, {detection_rate:.0f}%)"
    )
ax.axhline(detection_threshold, color="orange", linestyle="--", linewidth=0.9,
           label=f"Threshold = {detection_threshold:.0f} ({THRESHOLD_FACTOR:.0%} x max)")
ax.set_xlabel("Time (s)")
ax.set_ylabel("ADC counts (12-bit)")
ax.set_title(f"R-Peak Detection - {matched}/{len(true_peaks_adj)} matched ({detection_rate:.1f}%)")
ax.legend(loc="upper right", fontsize=8)
ax.grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig(os.path.join(PLOTS_DIR, "rpeak_detection.png"), dpi=150)
plt.close(fig)
print("  Saved rpeak_detection.png")

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
pass_fail = "PASS" if (snr_gain > 10.0 and detection_rate > 95.0) else "FAIL"

print("\n=== Algorithm Validation Summary ===")
print(f"FIR taps      : {N_TAPS}")
print(f"Passband      : {F_LOW} - {F_HIGH} Hz")
print(f"SNR raw       : {snr_raw:.1f} dB")
print(f"SNR filtered  : {snr_filtered:.1f} dB")
print(f"SNR gain      : {snr_gain:.1f} dB")
print(f"Peaks detected: {matched} / {len(true_peaks_adj)} ({detection_rate:.1f}%)")
print(f"BPM mean error: {bpm_error:.1f} BPM")
print(f"Threshold used: {threshold_12bit} (12-bit)")
print(f"Fixed-point Q  : Q1.15")
print(f"Accumulator    : 32-bit signed")
print(f"Output truncate: bits [26:15]")
print(pass_fail)

# ---------------------------------------------------------------------------
# Export coefficient data (read by CI / handoff writer)
# ---------------------------------------------------------------------------
print("\n--- Coefficient export (for algorithm_spec.md) ---")
for i, c in enumerate(fir_coeffs_q15):
    print(f"COEFF h[{i:2d}] = {c}")
print(f"THRESHOLD_12BIT = {threshold_12bit}")
print(f"SNR_GAIN = {snr_gain:.1f}")
print(f"DETECTION_RATE = {detection_rate:.1f}")
print(f"BPM_ERROR = {bpm_error:.1f}")
print(f"TRUE_PEAKS = {len(true_peaks_adj)}")
print(f"MATCHED_PEAKS = {matched}")
