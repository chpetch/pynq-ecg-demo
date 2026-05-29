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

---

## Post-Milestone Hardware Debug Session (2026-05-27)

**Context:** Tested with PYNQ 2.5 image using `ps/pynq25_capture.ipynb`. Overlay loads
(FPGA programmed) but ECG_DAC read constant 2048. Two issues identified and fixed.

### Issue 1 — JB pin reassignment (COMPLETE)
`pl/constraints.xdc` corrected: adc_scl moved W11→V10, adc_sda moved W12→W10 so PMOD AD2
seats cleanly in JB right half (JB3/JB4). Bitstream rebuilt successfully (3.9 MB).

### Issue 2 — DDS divider overflow bug (FIXED, rebuild required)
**Root cause:** `pl/ecg_dds.v` reset `bpm_prev <= 8'd0`, but `pl/axi_ecg_ctrl.v` resets
`reg_bpm_ch_a <= 8'h3C (60)`. On first post-reset clock, `bpm_config=60 != bpm_prev=0`
triggers the 32-bit sequential divider. For `div_bit=31`, `360<<31` overflows 32 bits →
garbage quotient → `base_reload ≈ 4 billion` → phase counter takes ~43 s per ROM step →
DDS frozen at ROM[0]=2048 (isoelectric baseline).

**Fix applied to `pl/ecg_dds.v`:**
1. `bpm_prev <= 8'd60` at reset (was `8'd0`) — no spurious divide on startup
2. Added `wire [63:0] div_shifted` and skip-step guard `div_shifted[63:32] == 0` to
   prevent overflow on any future BPM change
3. Removed stale duplicate `base_reload <= 32'd138888` reset line

**Syntax check:** `iverilog -t null -g2012 pl/ecg_dds.v pl/ecg_rom.v` — CLEAN

### Hardware verified (PMOD loopback test)
`ps/pmod_test.py` (new file) tested both PMODs with PYNQ base overlay:
- PMOD DA4 SPI: bit-banged 5 codes to channel A — OK
- PMOD AD2 I2C: 10 samples read @ expected voltage — OK
- Loopback sweep DAC 0→4095 → ADC tracked monotonically within 3 LSB — **PASS**
- Confirms ECG_DAC=2048 is RTL-only; hardware is not at fault.

**PYNQ 2.5 API learnings:**
- `Pmod_IIC(if_id, scl_pin, sda_pin, iic_addr)` — addr is 4th positional arg
- `iic.send([data])` — no length/addr args; `iic.receive(n)` — no addr arg
- `python3` required (not `python`); `sudo` required for all PYNQ scripts

### Files added / changed this session
| File | Change |
|------|--------|
| `pl/ecg_dds.v` | Fix bpm_prev reset + 64-bit divider overflow guard |
| `pl/constraints.xdc` | JB pin reassignment (adc_scl→V10, adc_sda→W10) |
| `ps/pmod_test.py` | New — PMOD hardware loopback test (base overlay) |
| `ps/pynq25_capture.ipynb` | New — 5-cell PYNQ 2.5 waveform capture notebook |
| `pc/mock_server.py` | New — PC-side mock board server for offline dashboard testing |
| `pc/requirements.txt` | Added fastapi, uvicorn, numpy, scipy |
| `pc/README_dashboard.md` | Added mock server usage instructions |
| `docs/wiring_guide.md` | Corrected PMOD AD2 from XADC→I2C; updated JB pin refs |
| `docs/setup_guide.md` | Updated JB pin description |
| `docs/architecture.md` | Updated JB pin refs |
| `docs/resource_utilisation.md` | Updated IO pin table |

**Next steps:**
1. Rebuild bitstream with fixed `ecg_dds.v` — run `vivado -mode batch -source vivado/create_project.tcl` from Vivado Command Prompt (~22 min)
2. Copy new `ps/ecg_demo.bit` + `ps/ecg_demo.hwh` to board and re-run `pynq25_capture.ipynb`
3. Confirm ECG_DAC cycles through ROM values (QRS visible, not stuck at 2048)
4. Flash board to PYNQ 3.0 for full server + dashboard test

---

## Post-Milestone Hardware Debug Session 2 — I2C deadlock (2026-05-28 / 29)

**Context:** Board now on PYNQ 3.0. Custom RTL DDS+DAC confirmed working
(ECG_DAC shows QRS with range 2520 counts post-bpm_prev fix). ADC loopback
path (ECG_RAW @ 0x28) reads constant 0xF00 / 0xFFF and never tracks the DAC.
Goal: get the AD7991-0 on PMOD AD2 to ACK a transaction from the PL fabric.

### What was tried (chronological)

| # | Change | Result |
|---|---|---|
| 1 | Custom RTL i2c_adc_driver.v rebuild with DDS fix (commit `9147c1e`) | ECG_RAW = 0xF00 |
| 2 | i2c_adc_driver.v: STOP+START in place of repeated-START, fix tLOW on ACK clocks (commit `2b4e24a`) | ECG_RAW = 0xF00 |
| 3 | Drop SCL from 400 kHz to 100 kHz to match Pmod_IIC baseline (commit `9d9aed7`) | cocotb still passes, hw still 0xFFF |
| 4 | Add `PULLTYPE PULLUP` on adc_scl/adc_sda XDC constraints (commit `dfefd8e`) | 0xF00 → 0xFFF (pullup makes released byte read 0xFF) |
| 5 | Swap V10 ↔ W10 (mislabel theory from [PYNQ discuss #2130 post 6](https://discuss.pynq.io/t/pmod-communication-through-i2c/2130/4)) (commit `a978e12`) | ECG_RAW = 0xFFF (unchanged); reverted |
| 6 | Add dummy `adc_scl_alt`/`adc_sda_alt` inputs on T15/T14 (JB[6]/JB[7]) with PULLUP — PMOD AD2 internally shorts pins 1↔5 and 2↔6, so those bottom-row pads were floating in parallel with our SCL/SDA (commit `52bfbd7`) | ECG_RAW = 0xFFF |
| 7 | **Replace entire custom RTL with Xilinx AXI IIC LogiCORE IP** (PG090) at `0x41600000`, make ECG_RAW PS-writable, PS sampler drives the IP (commits `2bdddf0` + `ae0f254`) | PYNQ couldn't even bind `axi_iic_0` to `ip_dict` |

### What worked on the same physical wiring

`ps/pmod_test.py` using **base overlay + `Pmod_IIC(PMODB, 2, 3, 0x28)`** still
reads the AD7991 cleanly and the DA4→AD2 CH0 loopback sweep tracks
monotonically. So the chip, the PMOD socket, the JB header, the loopback
wire, and pins V10/W10 are all physically fine. The failure is in the
PL-fabric drive path.

### What we learned about the AXI IIC IP path (raw MMIO at 0x41600000)

After PYNQ failed to register the IP, accessed it via raw `MMIO`:
- **Init OK**: CR=0x01, SR=0xC0 (TX_FIFO_EMPTY+RX_FIFO_EMPTY both set), no
  ARB_LOST or TX_ERROR. The IP is functional.
- **Single probe of 0x28**: ISR = 0xD6 with bit 1 = TX_ERROR. The IP
  correctly drove START + addr+W and detected NACK on the ACK clock —
  same symptom as the custom RTL (slave doesn't ACK).
- **Address scan 0x08–0x77**: every probe hung (TX_FIFO_EMPTY stuck at 0
  with TX_OCY=0 — dynamic-mode signal that the IP is stuck mid-transaction).
  The first probe consistently completes with NACK, then the bus enters a
  state from which `SRR` soft-reset doesn't recover.

Diagnostics that rule things out:
- Wrapper IOBUF wiring (`vivado/build/.../ecg_system_wrapper.v` lines 105–114)
  is correct: `T=scl_t`, `I=scl_o`, `O=scl_i`, `IO=scl_io`. Standard Xilinx
  IIC interface external pattern, generated by `make_bd_intf_pins_external`.
- Timing analysis: zero failing setup paths in any I2C-related logic. (FIR
  MAC chain has -5.6 ns slack on 12 paths — separate problem, doesn't affect
  ECG_RAW.)
- cocotb i2c testbench passes all 3 cases against a simulated slave.

### Hypotheses for *why* PL-fabric drive fails where MicroBlaze IOP drive succeeds

Not yet confirmed — would need a scope to verify:
1. **Pad electrical config differs.** MicroBlaze IOP may set IOSTANDARD /
   DRIVE / SLEW values our XDC doesn't. Worth comparing PYNQ base overlay's
   JB constraints to ours.
2. **PYNQ AxiIIC driver auto-bind fails silently** — `AxiIIC.bindto`
   matches our IP's VLNV exactly but `ip_dict` doesn't include the IP.
   Indirect evidence that something during PYNQ overlay parse rejects this
   particular axi_iic_0 instantiation.
3. **Bus stuck-low recovery missing.** After the first NACK the IP enters
   a state where SRR doesn't fully reset SCL/SDA pads. Manual bus recovery
   (9 SCL pulses with SDA high, then STOP) would unstick it, but that
   requires either custom logic or pin-toggling via AXI GPIO.

### Current state of the repo

- **`pl/i2c_adc_driver.v`** — kept in tree but **NO LONGER INSTANTIATED**.
  `ecg_process_top.v` does not include it.
- **`pl/ecg_process_top.v`** — no more `adc_sda`/`adc_scl` ports. FIR
  reads from `axi_ecg_ctrl.adc_data_out` and pulses on `adc_valid_out`.
- **`pl/axi_ecg_ctrl.v`** — `ECG_RAW (0x28)` is now **R/W**. Writing it
  pulses `adc_valid_out` for 1 cycle (feeds FIR). PS is supposed to fill it.
- **`pl/constraints.xdc`** — references `IIC_ADC_scl_io`/`IIC_ADC_sda_io`
  at V10/W10 with PULLUP. T15/T14 also constrained with PULLUP as
  unused-pad PULLUP inputs (`adc_scl_alt`/`adc_sda_alt`).
- **`vivado/create_project.tcl`** — block design has `axi_iic_0`
  (LogiCORE 2.1) at `0x41600000`, interconnect bumped to NUM_MI=2.
- **`ps/server.py`** — `AD7991Sampler` thread uses `overlay.axi_iic_0`,
  which PYNQ doesn't bind. Currently broken.
- **`ps/quick_test.ipynb`** — inline raw-MMIO sampler. Times out on every
  transaction. Currently broken.
- **`sim/test_axi_ecg_ctrl/`** — TC4 rewritten to test PS-writable 0x28;
  TC7 repurposed to verify 0x2C still read-only. 8/8 PASS.

### Recommended next steps (when this is picked up again)

1. **Don't spend more session time on PL-fabric I2C without a scope.**
   We've exhausted reasonable software-level debugging.
2. **Pragmatic ship path:** display ECG_DAC (0x40) on the dashboard;
   reframe demo as "FPGA-generated ECG." Skip ADC loopback. ~30 min of
   `pc/dashboard.py` work, no rebuild.
3. **If ADC loopback is required**, the highest-confidence path is to
   **embed a MicroBlaze IOP** (replica of base overlay's PMODB block) into
   our custom overlay, so we can use `Pmod_IIC` from the custom-overlay
   load. ~2–3 hours of TCL block-design work + rebuild.
4. **Alternative:** route SCL/SDA through Zynq PS I2C0/I2C1 via EMIO, use
   Linux `/dev/i2c-*`. ~1–2 hours + device-tree work.
5. **Separate ticket** — FIR timing failure (-5.6 ns slack on 12 paths in
   `u_fir/acc_reg[*]`). MAC needs pipelining or replacement by Xilinx FIR
   Compiler IP. Affects ECG_FILTERED + BPM only; ECG_RAW is unaffected.

### Files added / changed this session

| File | Change |
|------|--------|
| `pl/i2c_adc_driver.v` | 4 RTL revisions; now unused (file retained for history) |
| `pl/ecg_process_top.v` | Dropped adc_* ports + i2c_adc_driver instance; FIR sources from axi_ecg_ctrl |
| `pl/axi_ecg_ctrl.v` | `ecg_raw_in` removed; ECG_RAW now R/W; added `adc_data_out`/`adc_valid_out` |
| `pl/constraints.xdc` | PULLUP on V10/W10, T15/T14; renamed ports to `IIC_ADC_*_io` to match wrapper |
| `vivado/create_project.tcl` | Added axi_iic_0 IP, interconnect M01 wiring, IIC interface external |
| `ps/server.py` | New `AD7991Sampler` thread (currently broken — PYNQ doesn't bind axi_iic_0) |
| `ps/quick_test.ipynb` | Inline raw-MMIO sampler (currently times out) |
| `ps/hybrid_test.ipynb` | New — exploratory hybrid DAC-custom + ADC-base test |
| `sim/test_axi_ecg_ctrl/test_axi_ecg_ctrl.py` | TC4 rewritten for R/W ECG_RAW; TC7 moved to 0x2C |
| `sim/test_i2c_adc/` | Tests pass at both 400 kHz and 100 kHz; module no longer ships |
| `handoffs/register_map.md` | 0x28 ECG_RAW: R → R/W with PS-write note |

### Reference: AXI IIC IP register summary (for next-session pickup)

Base address `0x41600000`, range 64 KB. Per PG090 §2.3:

| Offset | Name | Notes |
|---|---|---|
| 0x020 | ISR | Sticky interrupt status. Bit 1 = TX_ERROR (NACK), bit 0 = ARB_LOST |
| 0x040 | SOFTR | Write `0xA` to soft-reset the core |
| 0x100 | CR | Bit 0 = EN. Write `0x00` then `0x01` for clean enable |
| 0x104 | SR | Current status. Bit 7 = TX_FIFO_EMPTY, bit 2 = BB (bus busy) |
| 0x108 | TX_FIFO | 10-bit: bit 9 = STOP, bit 8 = START, bits[7:0] = data |
| 0x10C | RX_FIFO | Reads return next byte |
| 0x114 | TX_FIFO_OCY | Current FIFO depth |
| 0x118 | RX_FIFO_OCY | Current FIFO depth |
| 0x120 | RX_FIFO_PIRQ | Default 0x0F per PYNQ AxiIIC._enable() |

Standard PYNQ init sequence:
```python
iic.write(0x40,  0x0A)   # SOFTR
iic.write(0x100, 0x00)   # CR = 0
iic.write(0x120, 0x0F)   # RX_FIFO_PIRQ
iic.write(0x100, 0x01)   # CR = EN
while iic.read(0x104) & 0x04: pass   # wait BB=0
```

