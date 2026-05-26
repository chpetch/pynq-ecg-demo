# FPGA Resource Utilisation

Target device: **Zynq xc7z020clg400-1** (PYNQ-Z2 PL fabric only)

| Resource | Available | Est. used | Est. % | Actual (post-impl) |
|----------|-----------|-----------|--------|--------------------|
| LUT      | 53,200    | ~3,200    | ~6%    | —                  |
| LUTRAM   | 17,400    | ~400      | ~2%    | —                  |
| FF       | 106,400   | ~2,000    | ~2%    | —                  |
| DSP48E1  | 220       | ~31       | ~14%   | —                  |
| BRAM     | 140       | 0         | 0%     | —                  |
| IO       | 125       | 7         | 6%     | —                  |

_Estimated figures from RTL analysis. Actual figures require Vivado synthesis + implementation report._

---

## Per-Module Breakdown

### Signal Generation (`ecg_signal_gen_top`)

| Module | LUT est. | FF est. | DSP est. | Notes |
|--------|----------|---------|----------|-------|
| `ecg_rom` ×8 | ~400 LUTRAM | — | — | 8× 512×12-bit distributed ROM; inferred as LUTRAM |
| `ecg_dds` ×8 | ~800 | ~640 | — | 8× phase counter + LFSR + multiplier (small); 100 LUT + 80 FF each |
| `spi_dac_driver` | ~200 | ~150 | — | FSM + 24-bit shift register |
| **Subtotal** | **~1,400** | **~790** | **0** | |

### Signal Processing (`ecg_process_top`)

| Module | LUT est. | FF est. | DSP est. | Notes |
|--------|----------|---------|----------|-------|
| `i2c_adc_driver` | ~200 | ~150 | — | FSM + byte shift register |
| `fir_filter` | ~300 | ~400 | ~31 | 31-tap direct form; each MAC maps to 1 DSP48E1 |
| `rpeak_detector` | ~150 | ~100 | — | Threshold compare + 16-bit counter + iterative BPM divider |
| `axi_ecg_ctrl` | ~350 | ~300 | — | AXI4-Lite slave + 17 registers |
| **Subtotal** | **~1,000** | **~950** | **~31** | |

### IO

| Signal | Pin | Direction |
|--------|-----|-----------|
| `dac_cs_n` | V15 (JA[0]) | Output |
| `dac_din`  | W15 (JA[1]) | Output |
| `dac_sclk` | T10 (JA[3]) | Output |
| `adc_sda`  | W12 (JB[0]) | Inout  |
| `adc_scl`  | W11 (JB[1]) | Output |
| _(2 reserved)_ | — | — |

---

## Notes

- **FIR DSP usage** is the largest single consumer (~14% of DSP48). Vivado may pipeline or share multipliers depending on constraints — actual count may differ.
- **ecg_rom** will be inferred as distributed RAM (LUTRAM) by Vivado since it is small (512×12-bit = 6,144 bits, well below one BRAM at 36 Kbits). No BRAM expected.
- **Total estimated PL usage** is well within budget — leaves >90% LUTs and >85% DSPs free for Zynq PS infrastructure (AXI interconnect, Proc Reset, Clocking Wizard add ~1,000 LUTs).
- Actual numbers: run Vivado **Project Summary → Utilization** after implementation, or extract from `<project>.runs/impl_1/<top>_utilization_placed.rpt`.

---

_Last updated: Milestone 3 — Signal Processing (estimates only; no synthesis run yet)_
