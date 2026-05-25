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

_Last updated: Milestone 1 — Signal Generation_
