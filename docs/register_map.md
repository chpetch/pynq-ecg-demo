# Register Map

## Base Address

```
0x43C00000
```

Assigned in the Vivado Block Design AXI interconnect. All offsets below are relative to this base. The AXI-Lite slave uses a 32-bit data bus and 32-bit address bus.

---

## ECG Signal Generation Registers

Set by: **pynq_ecg_gen** (written from PS via MMIO or PYNQ `mmio` overlay interface)

| Offset | Name | R/W | Bits | Description | Default | Set by |
|---|---|---|---|---|---|---|
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

### BPM Default Values

| Channel | Default BPM | Hex |
|---|---|---|
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

## Signal Processing Registers

Reserved for `pynq_ecg_process` agent — defined at Milestone 3.

| Offset | Name | R/W | Bits | Description | Default | Set by |
|---|---|---|---|---|---|---|
| 0x28 | (reserved) | — | — | pynq_ecg_process registers start here | — | TBD — pending Milestone 3 |
| 0x2C | (reserved) | — | — | TBD by pynq_ecg_process | — | TBD — pending Milestone 3 |
| 0x30 | (reserved) | — | — | TBD by pynq_ecg_process | — | TBD — pending Milestone 3 |
| 0x34 | (reserved) | — | — | TBD by pynq_ecg_process | — | TBD — pending Milestone 3 |
| 0x38 | (reserved) | — | — | TBD by pynq_ecg_process | — | TBD — pending Milestone 3 |
| 0x3C | (reserved) | — | — | TBD by pynq_ecg_process | — | TBD — pending Milestone 3 |

---

## Notes

1. Bits [31:8] of each generation register are reserved; read as 0.
2. BPM values outside 30–240 are not hardware-enforced; PS driver must clamp before writing.
3. `RR_FLUCT=0` and `AMP_FLUCT=0` produce a perfectly periodic, fixed-amplitude output.
4. All registers are accessible from PS user-space via `/dev/mem` or the PYNQ overlay `mmio` interface at base address `0x43C00000`.
5. The AXI-Lite slave must support byte-enable writes; upper bytes must not corrupt lower byte register contents.

---

_Last updated: Milestone 1 — Signal Generation_
