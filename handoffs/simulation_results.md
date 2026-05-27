# Simulation Results

| Module              | TCs | Pass | Fail | Notes                        |
|---------------------|-----|------|------|------------------------------|
| ecg_dds             |  6  |  6   |  0   |                              |
| spi_dac_driver      |  4  |  4   |  0   |                              |
| i2c_adc_driver      |  3  |  3   |  0   |                              |
| fir_filter          |  5  |  5   |  0   |                              |
| rpeak_detector      |  6  |  6   |  0   |                              |
| axi_ecg_ctrl        |  8  |  8   |  0   |                              |
| **TOTAL**           | 32  | 32   |  0   |                              |

**Result: ALL PASS**

XML results : `sim/results/*.xml`
Waveform    : `sim/test_ecg_dds/sim_build/ecg_dds.fst` (GTKWave compatible)
Run logs    : `sim/test_*/sim_build/` (cocotb output per module)

## Notes
- Waveforms default to FST format (not VCD). To view: `gtkwave sim/test_ecg_dds/sim_build/ecg_dds.fst`
- To force VCD output on a future run: add `COCOTB_RESULTS_FILE` and `WAVES=1` to the Makefile
- All 32 test cases verified against `handoffs/algorithm_spec.md` coefficients and `handoffs/register_map.md` offsets

## RTL Issues Found
None — all modules passed on first run.
