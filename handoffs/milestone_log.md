# Milestone Log

Running record of what each agent produced and why, maintained by the orchestrator.
Append a new entry after each user-approved milestone. Never delete earlier entries.

---

## Milestone 1 — Signal Generation (2026-05-25)

**Files produced:**
- `pl/ecg_rom.v` : 512-deep 12-bit synchronous ROM, 360 MIT-BIH Record 100 ECG samples
- `pl/ecg_dds.v` : DDS stepping through ROM at configurable BPM; dual 8-bit LFSR for RR and amplitude beat-to-beat variation; 1-cycle `sample_valid` strobe
- `pl/spi_dac_driver.v` : SPI Mode 2 master (CPOL=1 CPHA=0), 25 MHz, 8-frame burst keeping CS_N low across all 8 AD5628-1 channels
- `pl/ecg_signal_gen_top.v` : top-level — 8× independent `ecg_dds` at BPM 60/40/50/70/80/100/120/150; `sample_valid` from Ch A is the master trigger
- `handoffs/register_map.md` : AXI-Lite register map at 0x43C00000; BPM_CH_A–H at offsets 0x00–0x24; 0x28+ reserved for pynq_ecg_process
- `handoffs/adc_interface.md` : loopback signal spec — 12-bit, 360 Hz default, 1-cycle `sample_valid_out` at 100 MHz, DAC Vref 2.5 V note

**Key decisions:**
- 8 channels with different BPM rates (not identical): showcases all 8 AD5628-1 channels with clinically meaningful rates (bradycardia → vigorous exercise)
- LFSR polynomial x⁸+x⁶+x⁵+x⁴+1, seeds 0xA5 / 0x5A for RR and amplitude LFSRs (independent, different seeds to avoid correlation)
- `sample_valid` from Ch A only used as master SPI trigger; all 8 DDS instances run independently

**Issues / retries:**
- `spi_dac_driver.v:135` — bit-select on a function call result (`build_word(...)[23]`) is not valid Verilog-2001. Fixed by adding `wire [23:0] load_word` combinational assignment and referencing `load_word[23]` instead.
- Fix caught by `iverilog -t null -g2012 pl/*.v` before commit.

**Next agent must read:**
- `handoffs/register_map.md` : pynq_ecg_process must extend this table from offset 0x28; must not redefine 0x00–0x24
- `handoffs/adc_interface.md` : i2c_adc_driver timing and signal format

---

## Milestone 2 — Algorithm Design (2026-05-26)

**Files produced:**
- `algo/validate_algorithm.py` : generates noisy ECG, designs 31-tap FIR, simulates Q1.15 fixed-point, runs Pan-Tompkins detector, asserts SNR gain > 10 dB and detection rate > 95% — both PASS
- `handoffs/algorithm_spec.md` : definitive algorithm spec with exact Q1.15 coefficient table, threshold, refractory period, BPM formula — pynq_ecg_process must implement these numbers exactly
- `docs/algorithm_summary.md` : engineering doc with design rationale, coefficient table, validation results
- `docs/architecture.md` : Signal Processing Pipeline section appended

**Key decisions:**
- FIR over IIR: linear phase, unconditionally stable, maps to DSP48 slices
- 31 taps: minimum for −50 dB stopband at 50 Hz with Hamming window
- Simplified Pan-Tompkins: threshold comparison only — no multipliers in RTL
- Q1.15: 16-bit coefficients map directly to DSP48 18-bit inputs
- Threshold raised to 0.70 × max (not 0.60) after validation to avoid false detections from powerline residual

**Issues / retries:**
- None — validation passed on first run (SNR gain 11.7 dB, 9/9 peaks = 100%)

**Next agent must read:**
- `handoffs/algorithm_spec.md` : FIR coefficients (h[0]–h[30]), threshold 2983, refractory 72 — implement exactly, no deviations
- `handoffs/register_map.md` : add processing registers starting at 0x28; do not touch 0x00–0x24
- `handoffs/adc_interface.md` : i2c_adc_driver interface spec
