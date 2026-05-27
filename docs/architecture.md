# Architecture

## System Overview

The PYNQ-Z2 ECG Demo generates realistic 12-bit ECG waveforms in programmable logic (PL), outputs them as analog signals through a PMOD DA4 (AD5628-1) DAC, loops the analog signal back into a PMOD AD2 ADC, and streams the digitised samples over a WebSocket from the Zynq PS to a Streamlit dashboard running on a PC. The PS also exposes a REST API that the dashboard uses to configure per-channel heart rate, HRV, and amplitude parameters at runtime via AXI-Lite registers.

---

## Block Diagram

```mermaid
flowchart TD
    subgraph PL_GEN["Programmable Logic — Signal Generation"]
        ROM["ecg_rom\n360 samples · 12-bit"]
        DDS["ecg_dds ×8\nBPM 40 / 50 / 60 / 70 / 80 / 100 / 120 / 150"]
        SPIDRV["spi_dac_driver\nSPI Mode 2 · 25 MHz · 8-frame burst"]
        ROM -->|addr / data| DDS
        DDS -->|"sample_data[11:0] ×8\nsample_valid"| SPIDRV
    end

    SPIDRV -->|"JA: CS_N · SCLK · DIN"| DAC["PMOD DA4\nAD5628-1 · 12-bit · 8-ch SPI DAC"]
    DAC -->|"VOUT Ch A · 0–2.5 V\nloopback wire"| ADC["PMOD AD2\nAD7991-0 · 12-bit · I²C ADC"]

    subgraph PL_PROC["Programmable Logic — Signal Processing  _(Milestone 3)_"]
        I2C["i2c_adc_driver\n400 kHz · addr 0x28"]
        FIR["fir_filter\n31-tap FIR bandpass"]
        RPEAK["rpeak_detector\nPan-Tompkins threshold"]
        AXICTRL["axi_ecg_ctrl\nAXI-Lite slave · 0x43C00000"]
        I2C -->|"adc_data[11:0]\nadc_valid"| FIR
        FIR -->|"filtered[11:0]\nvalid"| RPEAK
        RPEAK -->|"bpm_out · rpeak_detected"| AXICTRL
        I2C -->|"ecg_raw[11:0]"| AXICTRL
        FIR -->|"ecg_filt[11:0]"| AXICTRL
    end

    ADC -->|"JB: SDA · SCL"| I2C

    subgraph PS["Processing System — Zynq PS"]
        SERVER["ps/server.py\nPYNQ 3.0 overlay"]
    end

    AXICTRL -->|"AXI-Lite reads\n32-bit · 0x43C00000"| SERVER

    subgraph PC["PC Dashboard"]
        DASH["pc/dashboard.py\nStreamlit"]
    end

    SERVER -->|"WebSocket ws://…:5000/ws\n360 Hz JSON frames"| DASH
    DASH -->|"REST POST /config\nBPM · HRV · amplitude"| SERVER
```

---

## Layer Summary

| Layer | Technology | Responsibility |
|---|---|---|
| PL — Signal Generation | Verilog (Vivado) | Synthesise ECG waveform; drive DAC via SPI |
| PL — Signal Processing | Verilog (Vivado) | FIR filter, R-peak detection, AXI registers |
| Hardware — DAC | PMOD DA4 / AD5628-1 on JA | 12-bit 8-channel SPI DAC; Ch A used for loopback |
| Hardware — ADC | PMOD AD2 on JB | XADC-compatible analogue input |
| PS — Server | Python / PYNQ overlay | Read AXI regs, stream samples, serve REST API |
| PC — Dashboard | Streamlit | Display waveform, BPM, sliders for config |

---

## Signal Generation Block

### Inputs

| Port | Width | Description |
|---|---|---|
| `clk` | 1 | 100 MHz system clock |
| `rst_n` | 1 | Active-low synchronous reset |
| `bpm_ch_a` … `bpm_ch_h` | 8 each | Per-channel heart rate, 30–240 BPM |
| `rr_fluct` | 8 | RR interval variation magnitude, 0–255 |
| `amp_fluct` | 8 | Peak amplitude variation magnitude, 0–255 |

### Outputs

| Port | Width | Description |
|---|---|---|
| `dac_cs_n` | 1 | SPI chip-select (active low) to PMOD DA4 |
| `dac_sclk` | 1 | SPI clock (25 MHz, CPOL=1 CPHA=0) |
| `dac_din` | 1 | SPI data (MSB first, 24 bits per channel frame) |
| `sample_valid_out` | 1 | Ch A sample strobe — 1 pulse per sample at 360 Hz default |

### Key Parameters

| Parameter | Value |
|---|---|
| ROM depth | 360 samples (one cardiac cycle, MIT-BIH Record 100 Lead II) |
| Sample rate | `bpm × 6` Hz per channel (default 360 Hz at 60 BPM) |
| DAC resolution | 12 bits unsigned (0–4095) |
| DAC channels driven | 8 (Ch A–H), each with independent DDS phase counter |
| SPI word format | 24 bits: CMD[23:20] ADDR[19:16] DATA[15:4] DC[3:0] |
| HRV mechanism | 8-bit LFSR modulates reload counter per cardiac cycle |
| Amplitude mechanism | Independent 8-bit LFSR scales ROM sample by ±`amp_fluct`/2 |
| Source files | See `pl/ecg_rom.v`, `pl/ecg_dds.v`, `pl/spi_dac_driver.v`, `pl/ecg_signal_gen_top.v` |

---

## Signal Processing Pipeline

### Flow

```
ADC (12-bit samples, 360 Hz)
  │
  ▼
FIR Bandpass Filter  (31-tap, 0.5–40 Hz, Q1.15, Hamming window)
  │  latency: 15 clock cycles
  ▼
R-Peak Detector  (Pan-Tompkins threshold, refractory = 72 samples)
  │  outputs: bpm_out (16-bit), rpeak_detected (1-bit)
  ▼
AXI-Lite Registers  (base 0x43C00000)
  │  readable by PS via PYNQ overlay
  ▼
PS / WebSocket → PC Dashboard
```

### Key Parameters

| Parameter | Value | Source |
|-----------|-------|--------|
| FIR taps | 31 | `handoffs/algorithm_spec.md` |
| Passband | 0.5 – 40.0 Hz | algorithm_spec.md |
| Window | Hamming | algorithm_spec.md |
| Q format | Q1.15 (16-bit signed) | algorithm_spec.md |
| Accumulator | 32-bit signed | algorithm_spec.md |
| Output truncation | `acc >> 15`, bits [11:0] | algorithm_spec.md |
| Filter latency | 15 clock cycles | algorithm_spec.md |
| R-peak algorithm | Simplified Pan-Tompkins | algorithm_spec.md |
| Detection threshold | 2983 (12-bit, 0.70 × max) | algorithm_spec.md |
| Refractory period | 72 samples (200 ms @ 360 Hz) | algorithm_spec.md |
| BPM formula | `(360 × 60) / sample_interval` | algorithm_spec.md |
| Interval counter | 16-bit (saturates → BPM = 0) | algorithm_spec.md |
| SNR improvement | 11.7 dB (validated) | `algo/validate_algorithm.py` |
| R-peak detection rate | 100.0% on validation signal | algo/validate_algorithm.py |

RTL implementation: `pl/fir_filter.v`, `pl/rpeak_detector.v` _(Milestone 3)_.
Full algorithm detail: `docs/algorithm_summary.md`.

---

## Vivado Block Design

### IP Blocks Required

| IP Block | Instance Name | Notes |
|----------|---------------|-------|
| Zynq-7000 PS | `processing_system7_0` | Enable AXI GP0 master port; configure DDR and UART as needed |
| AXI Interconnect | `axi_interconnect_0` | 1 master (PS GP0), 1 slave (ecg_process_top S_AXI) |
| ecg_signal_gen_top | `ecg_signal_gen_top_0` | Custom IP; add `pl/` sources as design sources |
| ecg_process_top | `ecg_process_top_0` | Custom IP; includes fir_filter, rpeak_detector, axi_ecg_ctrl |
| Processor System Reset | `proc_sys_reset_0` | Drives `peripheral_aresetn` to custom IPs |
| Clocking Wizard | `clk_wiz_0` | Input: 125 MHz PS FCLK_CLK0; Output: 100 MHz system clock |

### Connection Summary

| From | To | Signal |
|------|----|--------|
| `processing_system7_0` FCLK_CLK0 | `clk_wiz_0` clk_in1 | 125 MHz reference clock |
| `clk_wiz_0` clk_out1 | `ecg_signal_gen_top_0` clk | 100 MHz system clock |
| `clk_wiz_0` clk_out1 | `ecg_process_top_0` clk | 100 MHz system clock |
| `clk_wiz_0` clk_out1 | `axi_interconnect_0` ACLK | 100 MHz AXI clock |
| `clk_wiz_0` clk_out1 | `proc_sys_reset_0` slowest_sync_clk | Clock for reset synchroniser |
| `processing_system7_0` FCLK_RESET0_N | `proc_sys_reset_0` ext_reset_in | PS reset source |
| `proc_sys_reset_0` peripheral_aresetn | `ecg_signal_gen_top_0` rst_n | Active-low reset |
| `proc_sys_reset_0` peripheral_aresetn | `ecg_process_top_0` rst_n | Active-low reset |
| `proc_sys_reset_0` interconnect_aresetn | `axi_interconnect_0` ARESETN | AXI interconnect reset |
| `processing_system7_0` M_AXI_GP0 | `axi_interconnect_0` S00_AXI | PS AXI master to interconnect |
| `axi_interconnect_0` M00_AXI | `ecg_process_top_0` S_AXI | AXI slave at 0x43C00000 |
| `ecg_signal_gen_top_0` sample_valid_out | `ecg_process_top_0` sample_trigger | 360 Hz sample strobe |
| `ecg_process_top_0` bpm_ch_a … bpm_ch_h | `ecg_signal_gen_top_0` bpm_ch_a … bpm_ch_h | Per-channel BPM [7:0] |
| `ecg_process_top_0` rr_fluct | `ecg_signal_gen_top_0` rr_fluct | HRV magnitude [7:0] |
| `ecg_process_top_0` amp_fluct | `ecg_signal_gen_top_0` amp_fluct | Amplitude variation [7:0] |
| `ecg_signal_gen_top_0` dac_cs_n / dac_sclk / dac_din | Board pins V15 / T10 / W15 (JA) | SPI to PMOD DA4 |
| `ecg_process_top_0` adc_sda / adc_scl | Board pins W12 / W11 (JB) | I2C to PMOD AD2 |

### Address Editor Settings

| Slave | Offset Address | Range | High Address |
|-------|---------------|-------|--------------|
| `ecg_process_top_0` S_AXI | `0x43C0_0000` | 64K | `0x43C0_FFFF` |

### Build Steps (summary)

1. Create a new Vivado RTL project targeting the PYNQ-Z2 (xc7z020clg400-1).
2. Add all `pl/*.v` files as design sources.
3. Add `pl/constraints.xdc` as a constraints source.
4. Create a new Block Design; add and connect IP as listed above.
5. Right-click the block design → **Validate Design**.
6. Right-click the block design → **Create HDL Wrapper** (let Vivado manage the wrapper).
7. Run **Generate Bitstream**; export `.bit` and `.hwh` to `ps/`.

---

---

## PS ↔ PC Communication

### Protocol Diagram

```mermaid
sequenceDiagram
    participant PC as PC Dashboard<br/>(Streamlit)
    participant PS as PS Server<br/>(FastAPI / uvicorn)
    participant AXI as AXI-Lite Registers<br/>(0x43C00000)

    PC->>PS: HTTP GET /status
    PS->>AXI: MMIO read (BPM, signal_present)
    AXI-->>PS: register values
    PS-->>PC: JSON { bpm, signal_present, config }

    PC->>PS: HTTP POST /config { bpm, rr_fluct, amp_fluct, threshold }
    PS->>AXI: MMIO write (offsets 0x00–0x38)
    PS-->>PC: JSON { success: true }

    loop 360 Hz WebSocket stream
        AXI-->>PS: ECG_RAW, ECG_FILTERED, BPM_OUT, RPEAK_COUNT
        PS-->>PC: ws://…:5000/ws JSON frame
    end
```

### Endpoint Summary

| Endpoint | Direction | Protocol | Rate | Purpose |
|---|---|---|---|---|
| `ws://{board_ip}:5000/ws` | PS → PC | WebSocket | 360 Hz | Live ECG sample stream |
| `POST /config` | PC → PS | HTTP REST | On demand | Write BPM, HRV, amplitude, threshold registers |
| `GET /status` | PC → PS | HTTP REST | On demand | Read current config + signal_present flag |

Full request/response schemas: `docs/api_reference.md`.

---

## Project File Structure

```
pynq-ecg-demo/
├── algo/                          Algorithm validation scripts and plots
│   ├── validate_algorithm.py      FIR + R-peak Python validator (generates coefficients)
│   ├── preview_ecg.py             Quick ECG ROM preview helper
│   └── plots/                     Validation output figures (PNG)
│       ├── ecg_comparison.png     Raw vs filtered ECG comparison
│       ├── ecg_preview.png        ROM waveform preview
│       ├── filter_response.png    FIR frequency response (passband/stopband)
│       └── rpeak_detection.png    R-peak detection overlay
│
├── docs/                          Generated engineering documentation
│   ├── architecture.md            System block diagram, layer summary, all design sections
│   ├── wiring_guide.md            PMOD pin tables and loopback wiring
│   ├── algorithm_summary.md       FIR coefficients, R-peak parameters, validation results
│   ├── register_map.md            Full AXI-Lite register table (0x00–0x3C)
│   ├── simulation_report.md       Cocotb results table, coverage notes
│   ├── api_reference.md           WebSocket + REST JSON schemas
│   ├── setup_guide.md             End-to-end build, deploy, and run guide
│   └── resource_utilisation.md    Vivado synthesis LUT/FF/DSP utilisation report
│
├── handoffs/                      Shared contracts between milestone agents
│   ├── register_map.md            Authoritative register definitions (source for docs)
│   ├── algorithm_spec.md          FIR coefficients, R-peak thresholds, Q-format spec
│   ├── adc_interface.md           ADC pinout and I²C protocol spec
│   ├── ws_schema.json             WebSocket JSON packet schema
│   ├── simulation_results.md      Raw simulation pass/fail data (source for sim report)
│   └── milestone_log.md           Per-milestone completion log
│
├── pl/                            Verilog RTL source files (PL fabric)
│   ├── ecg_rom.v                  360-sample 12-bit ECG ROM (MIT-BIH Record 100)
│   ├── ecg_dds.v                  Per-channel DDS phase accumulator (8 instances)
│   ├── spi_dac_driver.v           SPI burst driver for AD5628-1 DAC
│   ├── ecg_signal_gen_top.v       Signal generation top-level (ROM + DDS × 8 + SPI)
│   ├── i2c_adc_driver.v           I²C master for AD7991-0 ADC at 400 kHz
│   ├── fir_filter.v               31-tap Q1.15 FIR bandpass filter
│   ├── rpeak_detector.v           Pan-Tompkins threshold R-peak detector + BPM LUT
│   ├── axi_ecg_ctrl.v             AXI-Lite slave register file (0x43C00000)
│   ├── ecg_process_top.v          Signal processing top-level (I2C + FIR + R-peak + AXI)
│   └── constraints.xdc            Vivado pin/timing constraints for PYNQ-Z2
│
├── ps/                            Zynq PS Python server (runs on board)
│   ├── server.py                  FastAPI server — PYNQ overlay, WebSocket, REST API
│   ├── overlay_test.ipynb         Jupyter notebook for interactive overlay testing
│   ├── requirements.txt           PS Python dependencies (fastapi, uvicorn, pynq)
│   ├── deploy.sh                  scp deploy script (usage: ./deploy.sh <board_ip>)
│   ├── start_server.sh            Launches uvicorn on port 5000
│   ├── ecg_demo.bit               FPGA bitstream (generated by Vivado)
│   └── ecg_demo.hwh               Hardware handoff file for PYNQ overlay
│
├── pc/                            PC-side Streamlit dashboard
│   ├── dashboard.py               Streamlit app — waveform, BPM, sliders, CSV export
│   ├── run_dashboard.sh           Launch script (streamlit run dashboard.py)
│   ├── requirements.txt           PC Python dependencies (streamlit, plotly, websockets)
│   └── README_dashboard.md        Dashboard usage instructions
│
├── sim/                           Cocotb testbenches (run under WSL with Icarus Verilog)
│   ├── run_all.sh                 Iterates all test_*/ dirs and runs make SIM=icarus
│   ├── Makefile                   Top-level sim Makefile
│   ├── results/                   JUnit XML results per module
│   ├── test_ecg_dds/              DDS testbench (6 test cases)
│   ├── test_ecg_dds_quick/        Fast DDS smoke test
│   ├── test_spi_dac/              SPI DAC driver testbench (4 test cases)
│   ├── test_i2c_adc/              I²C ADC driver testbench (3 test cases)
│   ├── test_fir_filter/           FIR filter testbench (5 test cases)
│   ├── test_rpeak_detector/       R-peak detector testbench (6 test cases)
│   └── test_axi_ecg_ctrl/         AXI-Lite register testbench (8 test cases)
│
├── vivado/                        Vivado TCL automation scripts
│   └── create_project.tcl         Batch script — creates project, builds block design,
│                                  runs bitstream, exports .bit + .hwh to ps/
│
├── scripts/                       Developer utility scripts
│   ├── swap_agent.sh              Switch active .claudeignore for a given agent
│   ├── plot_rom.py                Plot the ECG ROM samples
│   └── ignore_for_*.txt           Per-agent .claudeignore content
│
├── sessions/                      Session notes per date
│   ├── 2026-05-25.md              M1–M3 session log
│   └── 2026-05-26.md              M4–M7 session log
│
├── CLAUDE.md                      Orchestrator instructions and current milestone state
├── README.md                      Project overview and quick-start
├── SETUP.md                       Extended setup reference (model switching etc.)
└── init_project.sh                One-time project scaffold script
```

---

_Last updated: Milestone 7 — GUI Dashboard_
