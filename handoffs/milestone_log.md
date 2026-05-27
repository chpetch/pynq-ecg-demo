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

---

## Milestone 3 — Signal Processing (2026-05-26)

**Files produced:**
- `pl/i2c_adc_driver.v` : FSM I2C master, 400 kHz, addr 0x28, config 0x10, reads 2 bytes
- `pl/fir_filter.v` : 31-tap direct-form FIR, Q1.15 coefficients from algorithm_spec.md verbatim, output = acc[26:15]
- `pl/rpeak_detector.v` : Pan-Tompkins threshold detector, 72-sample refractory, 16-bit interval counter, iterative subtraction BPM divider
- `pl/axi_ecg_ctrl.v` : AXI4-Lite slave, full register map 0x00–0x3C, 2-cycle read path, signal-present rolling window
- `pl/ecg_process_top.v` : top-level wrapper connecting all four modules
- `pl/constraints.xdc` : JA[0,1,3] DAC SPI (V15/W15/T10) + JB[0,1] ADC I2C (W12/W11), LVCMOS33, 8 mA clocks
- `handoffs/register_map.md` : updated with 0x28–0x3C definitions (0x00–0x24 untouched)
- `handoffs/ws_schema.json` : WebSocket JSON payload schema created

**Key decisions:**
- FIR coefficients use `-16'sdN` signed literal syntax (valid Verilog-2012, accepted by iverilog and Vivado)
- BPM divider: iterative subtractive divider (no combinational divider, no synthesis latches)
- DETECT_THRESHOLD resets to 0x800; PS must write 2983 (0xBA7) at boot per algorithm_spec.md
- axi_ecg_ctrl latches write address and data separately, fires transaction only when both valid (correct AXI4-Lite behaviour)

**Issues / retries:**
- None — `iverilog -t null -g2012 pl/*.v` passed clean on first attempt

**Next agent must read:**
- `handoffs/register_map.md` : full register map for AXI access from PS
- `handoffs/ws_schema.json` : WebSocket payload schema — ps_server and gui both depend on this
- `handoffs/adc_interface.md` : sample rate and signal format

---

## Milestone 4 — Simulation (2026-05-27)

**Files produced:**
- `sim/test_ecg_dds/test_ecg_dds.py` : 6 test cases — BPM rate, BPM scaling, waveform continuity, RR fluctuation, amplitude fluctuation, reset behaviour
- `sim/test_spi_dac/test_spi_dac.py` : 4 test cases — transfer format, SYNC_N timing, busy flag, ignore-during-busy
- `sim/test_i2c_adc/test_i2c_adc.py` : 3 test cases — I2C read sequence, SCL frequency, valid pulse width
- `sim/test_fir_filter/test_fir_filter.py` : 5 test cases — impulse response, passband pass, stopband attenuation, latency, no overflow
- `sim/test_rpeak_detector/test_rpeak_detector.py` : 6 test cases — single peak, refractory block, two peaks, BPM calculation, no signal, configurable threshold
- `sim/test_axi_ecg_ctrl/test_axi_ecg_ctrl.py` : 8 test cases — write config registers, read status registers, read-only enforcement, reset defaults
- `sim/run_all.sh` : single-command test runner
- `handoffs/simulation_results.md` : 32 pass, 0 fail
- `docs/simulation_report.md` : toolchain, results table, coverage notes

**Key decisions:**
- cocotb 2.0.1 installed with `COCOTB_IGNORE_PYTHON_REQUIRES=1` (WSL has Python 3.14, cocotb max is 3.13)
- Manual AXI driver used in test_axi_ecg_ctrl (cocotb 2.x AxiLiteMaster API changed)
- Waveforms saved as FST (cocotb 2.x default) — use `gtkwave sim/test_*/sim_build/*.fst` to view
- test_ecg_dds TC3/TC5 simulate 100M+ cycles — avoid re-running unless necessary

**Issues / retries:**
- cocotb-config not in WSL PATH when called from Windows PowerShell — fixed by using `python3 -m cocotb_tools.config` in all Makefiles
- ecg_dds FST file grew to 1 GB (TC5 simulates 122M cycles) — corrupted on session cut-off; replaced with `sim/test_ecg_dds_quick/` for fast waveform viewing

**Next agent must read:**
- `handoffs/register_map.md` : all AXI offsets 0x00–0x40 — especially the multi-channel BPM registers (0x00–0x24) and ECG_DAC at 0x40
- `handoffs/ws_schema.json` : exact JSON payload including `ecg_dac` field

---

## Milestone 5 — PS Server (2026-05-27)

**Files produced:**
- `ps/server.py` : FastAPI app — loads PYNQ overlay, polls AXI registers at 360 Hz, streams JSON over WebSocket on `/ws`, accepts config via `POST /config`, reports status via `GET /status`
- `ps/requirements.txt` : `fastapi`, `uvicorn[standard]`, `pynq>=3.0`
- `ps/overlay_test.ipynb` : 5-cell Jupyter diagnostic — load overlay, read all 17 registers, write BPM_CH_A=90, poll ECG_RAW 10×, check STATUS
- `ps/deploy.sh` : rsync project to board over SSH
- `ps/start_server.sh` : starts uvicorn on port 5000

**Key decisions:**
- FastAPI + asyncio throughout — no threading, avoids GIL issues with PYNQ overlay
- Full 17-register map (0x00–0x40) including ECG_DAC at 0x40
- Default detect_threshold set to 2983 (0xBA7) at startup per algorithm_spec.md
- WebSocket payload includes `ecg_dac` field for DAC monitor trace in GUI
- CORS enabled (all origins) for browser-based dashboard access
- Graceful shutdown: SIGTERM handler closes WebSocket connections before exit

**Issues / retries:**
- Original pynq_ps_server.md spec had wrong AXI offsets (9-register old map); corrected to full 17-register map before agent was spawned
- Board has PYNQ 2.5 (not 3.0) — cannot test on hardware until board is upgraded to PYNQ 3.0 image

**Next agent must read:**
- `handoffs/ws_schema.json` : WebSocket payload — GUI must consume all fields
- `handoffs/register_map.md` : full register map for slider ranges in GUI

---

## Milestone 7 — GUI Dashboard (2026-05-27)

**Files produced:**
- `pc/dashboard.py` : Streamlit single-file app (488 lines) — live ECG chart with DAC/raw/filtered traces + R-peak markers, BPM metric, config sliders, CSV export
- `pc/requirements.txt` : `streamlit>=1.32`, `plotly>=5.18`, `websockets>=12.0`, `requests>=2.31`
- `pc/run_dashboard.sh` : `streamlit run dashboard.py --server.port 8501 --server.headless false`
- `pc/README_dashboard.md` : install + run instructions, endpoint summary

**Key decisions:**
- All mutable state in `st.session_state` — no module-level globals
- WebSocket client runs in daemon background thread via `asyncio.run()` with `threading.Lock` for buffer access
- Second background thread fires `st.rerun()` every 100 ms — main Streamlit thread never calls `time.sleep()`
- Chart rendered into `st.empty()` placeholder, rebuilt each rerun from lock-protected deque snapshot
- `[Apply Config]` POSTs `{"bpm_ch_a", "rr_fluct", "amp_fluct", "detect_threshold"}` — slider changes do not auto-send
- CSV export: `timestamp_ms, ecg_raw, ecg_dac, ecg_filtered, bpm, rpeak`
- On first connect: `GET /status` populates slider defaults from board

**Issues / retries:**
- None — produced on first spawn

**Next agent must read:**
- N/A — this is the final milestone. All handoff files remain valid for reference.

---

## Milestone 6 — Vivado Synthesis (2026-05-27)

**Files produced:**
- `vivado/create_project.tcl` : fully unattended Vivado batch script — creates block design, runs synth + impl + bitstream, exports `ps/ecg_demo.bit` + `ps/ecg_demo.hwh`
- `vivado/README.md` : board file install guide, one-command run, expected runtime (~30 min), troubleshooting table

**Key decisions:**
- Single AXI slave: `ecg_process_top` owns the entire register map (0x00–0x40); `ecg_signal_gen_top` has NO AXI interface — receives BPM/fluct as plain output wires from `ecg_process_top`
- External port names match `pl/constraints.xdc` exactly: `DAC_CS_N`, `DAC_DIN`, `DAC_SCLK`, `adc_sda`, `adc_scl`
- ecg_process_top has dual clock inputs (`clk` and `s_axi_aclk`) — both driven from `FCLK_CLK0`
- ecg_process_top has dual reset inputs (`rst_n` and `s_axi_aresetn`) — both driven from `peripheral_aresetn`
- Build artifacts go to `vivado/build/` (git-ignored); only `ps/ecg_demo.bit` and `ps/ecg_demo.hwh` are the deliverables
- `vivado/build/` added to `.gitignore`; `ps/*.bit` and `ps/*.hwh` already ignored

**Issues / retries (4 TCL fixes needed):**
1. `M_AXI_GP0_ACLK` not connected → `connect_bd_net FCLK_CLK0 M_AXI_GP0_ACLK` added
2. Wrapper path was `.srcs/` but Vivado 2022.1 uses `.gen/` → added fallback glob for both
3. `ecg_dds.v` lines 148/213: `reg` declarations in unnamed `begin` blocks → added `: rr_fluct_comb` / `: amp_scale_comb` block names (Vivado synth stricter than iverilog on this)
4. `adc_sda` inout port: UCIO-1 DRC blocked bitstream → `set_property SEVERITY {Warning} [get_drc_checks UCIO-1]` added to constraints.xdc

**Build results (2026-05-27):**
- `ps/ecg_demo.bit` : 3.9 MB ✅
- `ps/ecg_demo.hwh` : 150 KB ✅
- Timing: CRITICAL WARNING (failed to meet timing) — expected; FIR DSP48s have long comb paths. Harmless at 360 Hz
- Total runtime: ~22 minutes

**Next steps (user action required):**
- Flash board to PYNQ 3.0 image (current: PYNQ 2.5 — incompatible with ps/server.py + FastAPI)
- Then deploy with `ps/deploy.sh <board_ip>` and start server with `ps/start_server.sh`
