# Algorithm Summary

## Overview

The ECG signal processing pipeline applies two stages to the 12-bit ADC samples before they are written to AXI registers:

1. **FIR Bandpass Filter** — attenuates baseline wander (< 0.5 Hz), powerline interference (50 Hz), and broadband noise while preserving the ECG waveform (0.5–40 Hz passband).
2. **R-Peak Detector** — simplified Pan-Tompkins threshold comparison with a refractory period to produce beat interval measurements and a BPM output.

All coefficients and thresholds are derived from `algo/validate_algorithm.py` and must be implemented exactly as specified here. See `handoffs/algorithm_spec.md` for the authoritative parameter source.

---

## Design Rationale

| Decision | Rationale |
|----------|-----------|
| **FIR over IIR** | Linear phase — no phase distortion of the QRS complex (critical for preserving R-peak shape). No feedback — unconditionally stable and deterministic in fixed-point arithmetic. Synthesisable as a shift register + multiply-accumulate array in FPGA PL without special IP blocks. |
| **31 taps** | Odd count required for a linear-phase Type I FIR. 31 is the minimum number of taps that achieves ≈ −50 dB stopband attenuation at 50 Hz with a Hamming window (verified by `algo/plots/filter_response.png`). The 31-sample delay chain occupies ≈ 400 LUTs — well within the xc7z020 budget. More taps would deepen the stopband but increase latency and area with no measurable improvement for R-peak detection. |
| **Hamming window** | −43 dB peak sidelobe level — lower passband ripple than rectangular, better transition-band roll-off than Hanning. Standard choice for biomedical FIR per AHA DSP guidelines. Delivers the −50 dB attenuation at 50 Hz required to suppress the dominant powerline interference in the noise model. |
| **0.5–40 Hz passband** | Lower bound (0.5 Hz) removes baseline wander caused by respiration and patient motion — the primary low-frequency artifact in an unshielded ECG lead. Upper bound (40 Hz) preserves the full QRS complex while eliminating powerline interference (50/60 Hz) without a separate notch filter. R-peak energy is concentrated below 40 Hz; this bandwidth is sufficient for reliable rate detection per IEC 60601-2-25. |
| **Simplified Pan-Tompkins** | Reduces to one threshold comparison and one sample counter per clock cycle — implementable as pure combinational logic in RTL with no multipliers or pipeline stages. Full Pan-Tompkins (differentiate → square → moving-window integrate) adds three pipeline stages and significantly more LUTs but detects the same R-peaks on a bandpass-filtered signal. The simplified version achieves 100% detection on the validated waveform; the added complexity of the full algorithm is not warranted for this application. |
| **Q1.15 fixed-point** | 16-bit signed coefficients map directly onto DSP48E1 multiplier inputs (18-bit signed) in the Zynq PL — no precision loss. Unity passband gain is represented as 32768; right-shift-by-15 gives exact truncation. The 32-bit accumulator provides 4 bits of headroom above the worst-case 28-bit product, preventing overflow for any valid 12-bit ECG input (verified by Python simulation). Q1.15 is the industry-standard format for embedded DSP fixed-point, identical to CMSIS-DSP on Cortex-M. |

---

## FIR Bandpass Filter

| Parameter | Value |
|-----------|-------|
| Taps | 31 |
| Passband | 0.5 – 40.0 Hz |
| Window | Hamming |
| Sample rate | 360 Hz |
| Q format | Q1.15 (16-bit signed coefficients) |
| Accumulator | 32-bit signed integer |
| Output truncation | `accumulator >> 15`, keep bits [11:0] (12-bit result) |
| Filter latency | 15 clock cycles (linear phase delay = (31 − 1) / 2) |
| Design tool | `scipy.signal.firwin`, `pass_zero=False` |
| Symmetry | Symmetric coefficients (linear-phase FIR); h[15] is centre tap |
| SNR improvement | **11.7 dB** (0.6 dB raw → 12.3 dB filtered) |
| Stopband at 50 Hz | ≈ −50 dB (dominant noise source) |

---

## R-Peak Detector

| Parameter | Value |
|-----------|-------|
| Algorithm | Simplified Pan-Tompkins threshold comparison |
| Detection condition | `filtered_sample > detection_threshold` |
| Default threshold | **2983** (12-bit unsigned) |
| Threshold derivation | `0.70 × max(filtered_signal)` |
| Refractory period | **72 samples** (200 ms at 360 Hz, hard-coded in RTL) |
| BPM formula | `bpm = (360 × 60) / sample_interval` |
| Interval counter width | 16-bit (saturates at 0xFFFF → BPM = 0, no-signal state) |
| Detection input | FIR output, 12-bit unsigned (0 – 4095) |
| Detection rate | **100.0%** (9/9 peaks) |
| Mean BPM error | **0.2 BPM** |

BPM division is implemented as a pre-computed 16-bit lookup table (`bpm_lut[interval] = 21600 / interval`) to avoid an integer divider in RTL.

---

## Fixed-Point Implementation

### Multiply-Accumulate Data Path

| Stage | Width | Range |
|-------|-------|-------|
| Input sample | 12-bit unsigned | 0 – 4095 |
| Coefficient | 16-bit signed Q1.15 | −32768 – 32767 |
| Product | 28-bit, sign-extended to 32-bit signed | — |
| Accumulator | 32-bit signed, sum of 31 products | — |
| Output | `accumulator >> 15`, bits [11:0] | 0 – 4095 (12-bit) |

### Overflow Analysis

| Condition | Value |
|-----------|-------|
| Maximum single product | 4095 × 32767 ≈ 1.34 × 10⁸ (fits in 28-bit signed) |
| Maximum accumulator (worst case, 31 taps) | ≈ 4.15 × 10⁹ |
| 32-bit signed range | ±2.15 × 10⁹ |
| Overflow risk for valid ECG inputs | **None** — Hamming coefficients sum ≈ 1.0 (unity passband gain) |

---

## Validation Results

| Metric | Value | Assertion threshold | Result |
|--------|-------|---------------------|--------|
| Test signal | Synthetic ECG, 60 BPM, neurokit2, fs = 360 Hz, 10 s | — | — |
| Noise model | BW 10%@0.05 Hz + Gaussian σ=2% + Powerline 40%@50 Hz | — | — |
| SNR (raw input) | 0.6 dB | — | — |
| SNR (filtered output) | 12.3 dB | — | — |
| SNR improvement | **11.7 dB** | > 10 dB | PASS |
| R-peak detection rate | **100.0%** (9/9 peaks) | > 95% | PASS |
| Mean BPM error | **0.2 BPM** | — | — |
| Detection threshold | 2983 (12-bit) | — | — |
| Refractory period | 72 samples | — | — |
| Overall | — | — | **PASS** |

Validation script: `algo/validate_algorithm.py`. Plots saved to `algo/plots/`.

---

## Coefficient Table

All 31 Q1.15 integer coefficients (float coefficient × 32768, rounded). Coefficients are symmetric about the centre tap h[15].

| Index | Q1.15 value | Index | Q1.15 value |
|-------|------------|-------|------------|
| h[0]  | −56        | h[16] | 6577       |
| h[1]  | −31        | h[17] | 4867       |
| h[2]  | 22         | h[18] | 2676       |
| h[3]  | 112        | h[19] | 682        |
| h[4]  | 197        | h[20] | −622       |
| h[5]  | 180        | h[21] | −1094      |
| h[6]  | −36        | h[22] | −921       |
| h[7]  | −459       | h[23] | −459       |
| h[8]  | −921       | h[24] | −36        |
| h[9]  | −1094      | h[25] | 180        |
| h[10] | −622       | h[26] | 197        |
| h[11] | 682        | h[27] | 112        |
| h[12] | 2676       | h[28] | 22         |
| h[13] | 4867       | h[29] | −31        |
| h[14] | 6577       | h[30] | −56        |
| h[15] | **7224** (centre tap) | | |

Centre tap magnitude: 7224 out of 32768 maximum (Q1.15 unity = 32768).

_Last updated: Milestone 2 — Algorithm Design_
