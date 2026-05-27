# Simulation Report

## Toolchain

| Tool            | Version  |
|-----------------|----------|
| Icarus Verilog  | 12.0     |
| cocotb          | 2.0.1    |
| Waveform format | FST (GTKWave compatible) |

Simulations run under WSL (Ubuntu). Icarus is invoked via cocotb's `SIM=icarus` backend.

## How to Run

```bash
wsl -- bash -c "cd /mnt/d/programming/projects/pynq-ecg-demo/sim && ./run_all.sh"
```

`run_all.sh` iterates every `test_*/` subdirectory, calls `make SIM=icarus`, and exits non-zero if any suite reports `FAILED`. Per-suite logs are written to `sim/test_*/sim_build/run.log`.

To open a waveform after running:

```bash
wsl -- gtkwave sim/test_ecg_dds/sim_build/ecg_dds.fst
```

## Results Table

| Module           | TCs | Pass | Fail | Notes |
|------------------|-----|------|------|-------|
| ecg_dds          |  6  |  6   |  0   |       |
| spi_dac_driver   |  4  |  4   |  0   |       |
| i2c_adc_driver   |  3  |  3   |  0   |       |
| fir_filter       |  5  |  5   |  0   |       |
| rpeak_detector   |  6  |  6   |  0   |       |
| axi_ecg_ctrl     |  8  |  8   |  0   |       |
| **TOTAL**        | 32  | 32   |  0   |       |

**Result: ALL PASS**

Artefact locations:

| Artefact        | Path                                               |
|-----------------|----------------------------------------------------|
| JUnit XML       | `sim/results/*.xml`                                |
| Waveform (FST)  | `sim/test_ecg_dds/sim_build/ecg_dds.fst`          |
| Run logs        | `sim/test_*/sim_build/` (cocotb output per module) |

All 32 test cases verified against coefficients in `handoffs/algorithm_spec.md` and register offsets in `handoffs/register_map.md`.

## Coverage Notes

| Area                          | Covered | Detail |
|-------------------------------|---------|--------|
| DDS sine table output         | Yes     | 6 TCs across frequency/phase values |
| SPI DAC framing and timing    | Yes     | CS, SCLK, MOSI polarity and bit order |
| I2C ADC address and read cycle | Yes    | ACK/NACK, repeated start |
| FIR filter coefficients       | Yes     | Verified against `algorithm_spec.md` tap values |
| R-peak threshold logic        | Yes     | Above/below/edge cases |
| AXI-Lite register read/write  | Yes     | All offsets in `register_map.md` |
| Gate-level / post-synthesis   | No      | RTL-only simulation; no SDF back-annotation |
| Hardware-in-the-loop          | No      | Requires physical PYNQ-Z2 board (Milestone 5) |
| Noise/analogue front-end      | No      | ADC model is behavioural; no thermal or quantisation noise |

## Known Issues

None — all 32 test cases passed on first run. No RTL changes were required after simulation.

---

_Last updated: Milestone 4 — Simulation_
