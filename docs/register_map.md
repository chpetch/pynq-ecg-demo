# Register Map

## Base Address

```
0x43C00000
```

Assigned in the Vivado Block Design AXI interconnect. All offsets below are relative to this base. The AXI-Lite slave uses a 32-bit data bus and 32-bit address bus.

---

## Complete Register Table (0x00 – 0x3C)

| Offset | Name | R/W | Bits | Description | Default | Set by |
|--------|------|-----|------|-------------|---------|--------|
| 0x00 | BPM_CH_A | R/W | [7:0] | Ch A heart rate, 30–240 BPM | 0x3C (60) | pynq_ecg_gen |
| 0x04 | RR_FLUCT | R/W | [7:0] | RR interval variation, 0–255 | 0x00 | pynq_ecg_gen |
| 0x08 | AMP_FLUCT | R/W | [7:0] | Peak amplitude variation, 0–255 | 0x00 | pynq_ecg_gen |
| 0x0C | BPM_CH_B | R/W | [7:0] | Ch B heart rate, 30–240 BPM | 0x28 (40) | pynq_ecg_gen |
| 0x10 | BPM_CH_C | R/W | [7:0] | Ch C heart rate, 30–240 BPM | 0x32 (50) | pynq_ecg_gen |
| 0x14 | BPM_CH_D | R/W | [7:0] | Ch D heart rate, 30–240 BPM | 0x46 (70) | pynq_ecg_gen |
| 0x18 | BPM_CH_E | R/W | [7:0] | Ch E heart rate, 30–240 BPM | 0x50 (80) | pynq_ecg_gen |
| 0x1C | BPM_CH_F | R/W | [7:0] | Ch F heart rate, 30–240 BPM | 0x64 (100) | pynq_ecg_gen |
| 0x20 | BPM_CH_G | R/W | [7:0] | Ch G heart rate, 30–240 BPM | 0x78 (120) | pynq_ecg_gen |
| 0x24 | BPM_CH_H | R/W | [7:0] | Ch H heart rate, 30–240 BPM | 0x96 (150) | pynq_ecg_gen |
| 0x28 | ECG_RAW | R | [11:0] | Latest raw ADC sample from AD7991-0 | 0x000 | pynq_ecg_process |
| 0x2C | ECG_FILTERED | R | [11:0] | Latest FIR-filtered ECG sample | 0x000 | pynq_ecg_process |
| 0x30 | BPM_OUT | R | [7:0] | Live BPM from R-peak detector | 0x00 | pynq_ecg_process |
| 0x34 | RPEAK_COUNT | R | [15:0] | Rolling R-peak event counter (wraps at 0xFFFF) | 0x0000 | pynq_ecg_process |
| 0x38 | DETECT_THRESHOLD | R/W | [11:0] | R-peak detection threshold | 0x800 (2048) | PS |
| 0x3C | STATUS | R | [1:0] | [0]=signal_present [1]=lead_off | 0x00 | pynq_ecg_process |

---

## ECG Signal Generation Registers (0x00 – 0x24)

Set by: **pynq_ecg_gen**

### BPM Default Values

| Channel | Default BPM | Hex |
|---------|-------------|-----|
| A | 60 | 0x3C |
| B | 40 | 0x28 |
| C | 50 | 0x32 |
| D | 70 | 0x46 |
| E | 80 | 0x50 |
| F | 100 | 0x64 |
| G | 120 | 0x78 |
| H | 150 | 0x96 |

### BPM Reload Formula

```
sample_rate = bpm × 6   (samples/sec)
base_reload = 100_000_000 / (bpm × 6) − 1

Min BPM = 30  → base_reload = 555554
Max BPM = 240 → base_reload = 69443
```

---

## Signal Processing Registers (0x28 – 0x3C)

Set by: **pynq_ecg_process** (read-only registers updated from pipeline); **PS** writes `DETECT_THRESHOLD`.

### Register Details

**`ECG_RAW` (0x28)** — Updates every ADC sample cycle (~360 Hz). Reads 0x000 if no ADC conversion is in progress.

**`ECG_FILTERED` (0x2C)** — FIR output, 2-cycle latency behind `ECG_RAW`. The accumulator is right-shifted 15 bits and bits [11:0] are kept.

**`BPM_OUT` (0x30)** — Updated after each confirmed R-peak. Reads 0x00 when the interval counter saturates at 0xFFFF (no-signal state). BPM formula: `(360 × 60) / sample_interval`.

**`RPEAK_COUNT` (0x34)** — 16-bit rolling counter; increments by 1 on each `rpeak_detected` pulse. Wraps silently at 0xFFFF.

**`DETECT_THRESHOLD` (0x38)** — Default reset value is 0x800 (2048). The PS driver writes 0xBA7 (2983) at startup per `handoffs/algorithm_spec.md`. Byte-enable aware: byte 0 sets bits [7:0], byte 1 sets bits [11:8].

**`STATUS` (0x3C)**

| Bit | Name | Description |
|-----|------|-------------|
| [0] | signal_present | Set if any raw sample > 0x010 in the past 1000 clock cycles; cleared at start of each 1000-cycle window |
| [1] | lead_off | Reserved; reads 0 |

---

## Vivado Address Editor Setup

### Base Address Assignment

1. Open the **Address Editor** tab in Vivado Block Design (Window → Address Editor).
2. Locate `ecg_process_top` → `S_AXI` in the slave list.
3. Set **Offset Address** to `0x43C0_0000`.
4. Set **Range** to `64K` (0x10000).
5. Confirm **High Address** shows `0x43C0_FFFF`.
6. Re-run **Validate Design** after any address change.

### PS Access (PYNQ Overlay)

```python
from pynq import MMIO
ecg = MMIO(0x43C00000, 0x10000)

# Read BPM
bpm = ecg.read(0x30) & 0xFF

# Write threshold
ecg.write(0x38, 2983)
```

### PS Access (/dev/mem)

```bash
devmem2 0x43C00030 w   # read BPM_OUT
devmem2 0x43C00038 w 0xBA7   # write DETECT_THRESHOLD
```

---

## Notes

1. Bits [31:8] of each 8-bit generation register are reserved; read as 0.
2. Bits [31:12] of `ECG_RAW`, `ECG_FILTERED`, and `DETECT_THRESHOLD` are zero-padded.
3. Bits [31:16] of `RPEAK_COUNT` are zero-padded.
4. Bits [31:2] of `STATUS` are zero-padded.
5. BPM values outside 30–240 are not hardware-enforced; PS driver must clamp before writing.
6. `RR_FLUCT=0` and `AMP_FLUCT=0` produce a perfectly periodic, fixed-amplitude output.
7. The AXI-Lite slave supports byte-enable writes; upper bytes do not corrupt lower byte register contents.

---

_Last updated: Milestone 3 — Signal Processing_
