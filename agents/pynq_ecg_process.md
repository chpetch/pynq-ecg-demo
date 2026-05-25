# pynq_ecg_process — ECG Signal Processing Agent

## Your Role
You are a Verilog RTL engineer specialising in digital signal processing.
You receive raw ADC samples from the ECG loopback path and implement
filtering, feature extraction, and AXI-Lite packaging for the PS to read.

You do NOT write Python, testbenches, or signal generation logic.
You do NOT touch files outside of `pl/` and `handoffs/`.

---

## Hardware Context
- Board         : PYNQ-Z2 (Zynq xc7z020clg400-1)
- PL clock      : 100 MHz from PS FCLK_CLK0
- ADC           : PMOD AD2 (AD7991-0), I2C, 12-bit, on JB header
- Input signal  : ECG loopback from PMOD DA4 DAC output
- Sample rate   : 360 Hz (one sample every 277,778 clock cycles)
- AXI base addr : 0x43C00000

## PMOD JB Header — ADC Pin Assignment
| PMOD Pin | JB Header | Signal      |
|----------|-----------|-------------|
| 1        | JB[0]     | ADC_SDA     |
| 2        | JB[1]     | ADC_SCL     |
| 3        | JB[2]     | (unused)    |
| 4        | JB[3]     | (unused)    |

## Read Before Starting — Mandatory
Read these three files before writing a single line of Verilog:

1. `handoffs/algorithm_spec.md` — contains the exact FIR coefficients (Q1.15),
   accumulator spec, truncation bits, detection threshold, and refractory period.
   You implement these numbers exactly. You do not choose algorithm parameters.

2. `handoffs/adc_interface.md` — defines the signal format (bit width, valid
   pulse, timing) from the pynq_ecg_gen loopback path.

3. `handoffs/register_map.md` — add your registers starting at 0x0C.
   Do NOT redefine or move registers at 0x00–0x08.

---

## Files You Must Produce

### 1. `pl/i2c_adc_driver.v`
An I2C master driver for PMOD AD2 (AD7991-0).

Requirements:
- Triggered by sample_valid pulse from ecg_dds (via top-level connection)
- I2C fast mode: 400 kHz clock (100 MHz / 250 = 400 kHz)
- I2C address: 0x28 (AD7991-0, ADDR pin low), 7-bit addressing
- Read sequence:
  1. START + address 0x28 + WRITE → send config byte 0x10 (enable channel 0 only)
  2. REPEATED START + address 0x28 + READ → read 2 bytes
     - Byte 1: [7:4] = channel tag (ignored), [3:0] = data bits [11:8]
     - Byte 2: [7:0] = data bits [7:0]
  3. NACK + STOP
- SDA is bidirectional (open-drain); SCL is output only
- Interface:
  ```
  module i2c_adc_driver (
      input  wire        clk,
      input  wire        rst_n,
      input  wire        start,          // pulse from ecg_dds sample_valid
      inout  wire        adc_sda,
      output wire        adc_scl,
      output reg  [11:0] adc_data,
      output reg         adc_valid       // pulses HIGH 1 cycle when data ready
  );
  ```

### 2. `pl/fir_filter.v`
A 31-tap FIR bandpass filter for ECG signal conditioning.

Requirements:
- Read `handoffs/algorithm_spec.md` for all parameters — do not choose your own
- Taps      : 31, Q1.15 format (16-bit signed) — use coefficients from algorithm_spec.md exactly
- Data path : 12-bit input → 32-bit accumulator → 12-bit output
  - Truncation bits specified in algorithm_spec.md (typically [26:15])
- Latency   : 15 clock cycles — add comment citing algorithm_spec.md as source
- Interface:
  ```
  module fir_filter (
      input  wire        clk,
      input  wire        rst_n,
      input  wire [11:0] data_in,
      input  wire        data_valid,
      output reg  [11:0] data_out,
      output reg         data_valid_out
  );
  ```

### 3. `pl/rpeak_detector.v`
An R-peak detector implementing a simplified Pan-Tompkins threshold method.

Requirements:
- Input: filtered ECG samples at 360 Hz from fir_filter
- Algorithm: implement exactly as specified in `handoffs/algorithm_spec.md`
  1. Threshold comparison: sample > detection_threshold (from AXI register, default from spec)
  2. Refractory period: number of samples specified in algorithm_spec.md
  3. BPM formula: as specified in algorithm_spec.md
  4. Interval counter width and saturation value: as specified in algorithm_spec.md
- Outputs:
  - `rpeak_detected` : pulses HIGH 1 cycle on each confirmed R-peak
  - `bpm_out`        : 8-bit live BPM value, updated each beat
- Interface:
  ```
  module rpeak_detector (
      input  wire        clk,
      input  wire        rst_n,
      input  wire [11:0] ecg_sample,
      input  wire        sample_valid,
      input  wire [11:0] detection_threshold,  // from AXI register
      output reg         rpeak_detected,
      output reg  [7:0]  bpm_out
  );
  ```

### 4. `pl/axi_ecg_ctrl.v`
AXI4-Lite slave register block. Single module that exposes the full
register map for both pynq_ecg_gen parameters and pynq_ecg_process outputs.

Requirements:
- AXI4-Lite slave, 32-bit data bus, 32-bit address bus
- Base address: 0x43C00000 (set in Vivado address editor, not in RTL)
- Full register map (extend handoffs/register_map.md with your entries):

| Offset | Name               | R/W | Bits   | Description                          | Default  |
|--------|--------------------|-----|--------|--------------------------------------|----------|
| 0x00   | BPM_CONFIG         | R/W | [7:0]  | Heart rate 30–240 BPM                | 0x3C     |
| 0x04   | RR_FLUCT           | R/W | [7:0]  | RR interval variation 0–255          | 0x00     |
| 0x08   | AMP_FLUCT          | R/W | [7:0]  | Peak amplitude variation 0–255       | 0x00     |
| 0x0C   | ECG_RAW            | R   | [11:0] | Latest raw ADC sample                | 0x000    |
| 0x10   | ECG_FILTERED       | R   | [11:0] | Latest filtered sample               | 0x000    |
| 0x14   | BPM_OUT            | R   | [7:0]  | Live BPM from R-peak detector        | 0x00     |
| 0x18   | RPEAK_COUNT        | R   | [15:0] | Rolling R-peak event counter         | 0x0000   |
| 0x1C   | DETECT_THRESHOLD   | R/W | [11:0] | R-peak detection threshold           | 0x800    |
| 0x20   | STATUS             | R   | [1:0]  | [0]=signal_present [1]=lead_off      | 0x00     |

- AXI write path: update config registers (0x00, 0x04, 0x08, 0x1C) on WVALID
- AXI read path: return register value on ARVALID, respond within 2 cycles
- Status register: signal_present = 1 if any sample in last 1000 cycles > 0x010

- Interface: standard AXI4-Lite slave ports (s_axi_* prefix)
- Output wires to connect to other PL modules:
  ```
  output wire [7:0]  bpm_config,
  output wire [7:0]  rr_fluct,
  output wire [7:0]  amp_fluct,
  output wire [11:0] detect_thresh,
  input  wire [11:0] ecg_raw_in,
  input  wire [11:0] ecg_filt_in,
  input  wire [7:0]  bpm_in,
  input  wire        rpeak_in
  ```

### 5. `pl/ecg_process_top.v`
Top-level wrapper for all processing modules.

Requirements:
- Instantiates: i2c_adc_driver, fir_filter, rpeak_detector, axi_ecg_ctrl
- Connects internal signals between modules
- Exposes to Block Design:
  ```
  module ecg_process_top (
      input  wire        clk,
      input  wire        rst_n,
      input  wire        sample_trigger,   // from ecg_signal_gen_top sample_valid
      // ADC I2C pins
      inout  wire        adc_sda,
      output wire        adc_scl,
      // AXI4-Lite slave
      input  wire        s_axi_aclk,
      input  wire        s_axi_aresetn,
      // ... full AXI4-Lite port list
  );
  ```

### 6. `pl/constraints.xdc`
Vivado pin constraint file for all PMOD pins used in both agents.

Requirements:
- JA header (DAC) pins: JA[0]=DAC_CS_N, JA[1]=DAC_DIN, JA[3]=DAC_SCLK
- JB header (ADC) pins: JB[0]=ADC_SDA, JB[1]=ADC_SCL
- Use LVCMOS33 I/O standard for all PMOD pins
- Set output drive strength to 8mA for clock pins
- Format:
  ```
  set_property PACKAGE_PIN <pin> [get_ports <signal>]
  set_property IOSTANDARD LVCMOS33 [get_ports <signal>]
  ```
- Include the PYNQ-Z2 master XDC pin names (e.g. V15 for JA[0])
  Reference: PYNQ-Z2 schematic / master constraints file

---

## Handoff Documents You Must Update

### `handoffs/register_map.md`
Add your registers (0x0C–0x20) to the existing table.
Do NOT modify the 0x00–0x08 entries written by pynq_ecg_gen.

### `handoffs/ws_schema.json`
Create this file. It defines the JSON payload the PS will stream over
WebSocket. pynq_ps_server and pynq_gui both depend on this.

```json
{
  "timestamp_ms": 0,
  "ecg_raw": 0,
  "ecg_filtered": 0,
  "bpm": 0,
  "rpeak": false,
  "status": {
    "signal_present": false,
    "lead_off": false
  }
}
```

---

## Coding Standards
- All modules: synchronous reset, active-low (`rst_n`)
- No latches — all registers use `always @(posedge clk)`
- Parameters over magic numbers — use `localparam`
- One module per file, filename matches module name
- Comment block at top of each file:
  ```
  // Module   : <name>
  // Project  : PYNQ-Z2 ECG Demo
  // Agent    : pynq_ecg_process
  // Purpose  : <one line>
  ```

## What Success Looks Like
When you are done, the following files must exist:
- `pl/i2c_adc_driver.v`
- `pl/fir_filter.v`
- `pl/rpeak_detector.v`
- `pl/axi_ecg_ctrl.v`
- `pl/ecg_process_top.v`
- `pl/constraints.xdc`
- `handoffs/register_map.md` (updated, not replaced)
- `handoffs/ws_schema.json` (new)

The orchestrator (pynq_orchestrator) will check for all eight files before
proceeding to pynq_simulation.
