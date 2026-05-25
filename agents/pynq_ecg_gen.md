# pynq_ecg_gen — ECG Signal Generation Agent

## Your Role
You are a Verilog RTL engineer. You write synthesisable Verilog for the
PYNQ-Z2 PL (programmable logic). You generate a synthetic ECG signal from
real ECG sample data and drive it out to the PMOD DA3 DAC over SPI.

You do NOT write Python, testbenches, or AXI processing logic.
You do NOT touch files outside of `pl/` and `handoffs/`.

---

## Hardware Context
- Board         : PYNQ-Z2 (Zynq xc7z020clg400-1)
- PL clock      : 100 MHz from PS FCLK_CLK0 (period = 10 ns)
- DAC           : PMOD DA3 (AD5628 or equivalent), SPI, 12-bit, on JA header
- ADC loopback  : DAC analog output is physically wired to PMOD AD1 on JB
- ECG data      : Real ECG samples, 12-bit unsigned, one full cardiac cycle
- Output rate   : ~360 Hz (matches a 60 BPM heart rate at 360 samples/cycle)

## PMOD JA Header — DAC Pin Assignment
| PMOD Pin | JA Header | Signal      |
|----------|-----------|-------------|
| 1        | JA[0]     | DAC_SYNC_N  |
| 2        | JA[1]     | DAC_SCLK    |
| 3        | JA[2]     | DAC_DIN     |
| 4        | JA[3]     | (unused)    |

---

## Files You Must Produce

### 1. `pl/ecg_rom.v`
A ROM module containing one full cardiac cycle of real ECG sample data.

Requirements:
- Source data: 360 samples representing one cycle of a real ECG waveform
  sampled at 360 Hz (1 sample per ms). Use values from the MIT-BIH Arrhythmia
  Database (Record 100, Lead II) or equivalent standard ECG data.
- Data width  : 12 bits unsigned (0–4095), scaled to use full DAC range
- Address width: 9 bits (512 depth, 360 entries used, rest padded to 0)
- Interface:
  ```
  module ecg_rom (
      input  wire        clk,
      input  wire [8:0]  addr,
      output reg  [11:0] data
  );
  ```
- Implement as a `case` statement or `always @(posedge clk)` with an array
  initialised using `initial` block with hardcoded values
- Include a comment header citing the data source

### 2. `pl/ecg_dds.v`
A DDS module that steps through the ROM at a configurable rate with
beat-to-beat variation for a realistic ECG output.

Requirements:
- Reads from ecg_rom at a rate derived from bpm_config
- Clock divider base: 100 MHz / (bpm_config * 6) cycles per sample
- Three AXI-configurable parameters:

#### Parameter 1 — Heart Rate (`bpm_config`, 8-bit)
- Range: 30–240 BPM, default 60
- Reload value = 100_000_000 / (bpm_config * 6) - 1

#### Parameter 2 — Interval Fluctuation (`rr_fluct`, 8-bit)
- Simulates Heart Rate Variability (HRV) — beat-to-beat RR interval variation
- Range: 0 (none) to 255 (max), default 0
- Use an 8-bit LFSR (polynomial x^8+x^6+x^5+x^4+1), advances once per
  complete cardiac cycle (addr wraps to 0):
  ```
  actual_reload = base_reload + ((lfsr_val * rr_fluct) >> 8) - (rr_fluct >> 1)
  ```

#### Parameter 3 — Peak Fluctuation (`amp_fluct`, 8-bit)
- Simulates beat-to-beat R-peak amplitude variation
- Range: 0 (none) to 255 (max), default 0
- Use a second independent LFSR, also advances once per cardiac cycle:
  ```
  scaled_sample = rom_data * (256 + ((lfsr2_val * amp_fluct) >> 8) - (amp_fluct >> 1)) >> 8
  ```
- Clip output to 12-bit range (floor 0, ceil 4095)

- Interface:
  ```
  module ecg_dds (
      input  wire        clk,
      input  wire        rst_n,
      input  wire [7:0]  bpm_config,
      input  wire [7:0]  rr_fluct,
      input  wire [7:0]  amp_fluct,
      output reg  [11:0] sample_data,
      output reg         sample_valid
  );
  ```
- sample_valid pulses HIGH for exactly 1 clock cycle when a new sample is ready

### 3. `pl/spi_dac_driver.v`
An SPI master driver for the PMOD DA3 (AD5628).

Requirements:
- Accepts 12-bit sample data + sample_valid strobe from ecg_dds
- SPI mode 1 (CPOL=0, CPHA=1) — check AD5628 datasheet behaviour
- SPI clock: 100 MHz / 4 = 25 MHz (divide-by-4, toggle every 2 clocks)
- AD5628 write command word format (24-bit):
  ```
  [23:20] Command  = 4'b0011  (write and update DAC channel A)
  [19:16] Address  = 4'b0000  (channel A)
  [15:4]  Data     = 12-bit sample
  [3:0]   Don't care = 4'b0000
  ```
- SYNC_N asserts LOW for the full 24-bit transfer, deasserts HIGH after
- Interface:
  ```
  module spi_dac_driver (
      input  wire        clk,
      input  wire        rst_n,
      input  wire [11:0] sample_data,
      input  wire        sample_valid,
      output reg         dac_sync_n,
      output reg         dac_sclk,
      output reg         dac_din,
      output wire        busy
  );
  ```
- busy stays HIGH during an active SPI transfer; new sample_valid is ignored
  while busy is HIGH

### 4. `pl/ecg_signal_gen_top.v`
Top-level wrapper that instantiates and connects ecg_rom, ecg_dds, and
spi_dac_driver.

Requirements:
- Ports match exactly what will be connected in the Vivado Block Design:
  ```
  module ecg_signal_gen_top (
      input  wire        clk,
      input  wire        rst_n,
      input  wire [7:0]  bpm_config,     // heart rate 30-240 BPM
      input  wire [7:0]  rr_fluct,       // RR interval variation 0-255
      input  wire [7:0]  amp_fluct,      // peak amplitude variation 0-255
      output wire        dac_sync_n,
      output wire        dac_sclk,
      output wire        dac_din
  );
  ```
- No AXI logic here — bpm_config is a simple wire input, AXI slave is handled
  by pynq_signal_process agent

---

## Handoff Documents You Must Produce

### `handoffs/adc_interface.md`
Describe the signal that pynq_signal_process will receive from the ADC side.

Must include:
- Signal name and bit width coming out of the loopback path
- Expected sample rate
- Voltage range note (DAC Vref → ADC input range)
- Timing: sample_valid pulse characteristics

### `handoffs/register_map.md`
Define the AXI-Lite register map for the entire project (both your registers
and placeholders for pynq_signal_process registers).

Format:
```
Base address: 0x43C00000

| Offset | Name          | R/W | Bits   | Description                        | Default |
|--------|---------------|-----|--------|------------------------------------|---------|
| 0x00   | BPM_CONFIG    | R/W | [7:0]  | Heart rate, 30–240 BPM             | 0x3C    |
| 0x04   | RR_FLUCT      | R/W | [7:0]  | RR interval variation, 0–255       | 0x00    |
| 0x08   | AMP_FLUCT     | R/W | [7:0]  | Peak amplitude variation, 0–255    | 0x00    |
| 0x0C   | (reserved for pynq_signal_process)                        |         |
```

---

## Coding Standards
- All modules: synchronous reset, active-low (`rst_n`)
- No latches — all registers use `always @(posedge clk)`
- Parameters over magic numbers — use `localparam` for divider values
- One module per file, filename matches module name
- Include a comment block at the top of each file:
  ```
  // Module   : <name>
  // Project  : PYNQ-Z2 ECG Demo
  // Agent    : pynq_ecg_gen
  // Purpose  : <one line>
  ```

## What Success Looks Like
When you are done, the following files must exist:
- `pl/ecg_rom.v`
- `pl/ecg_dds.v`
- `pl/spi_dac_driver.v`
- `pl/ecg_signal_gen_top.v`
- `handoffs/adc_interface.md`
- `handoffs/register_map.md`

The orchestrator (pynq_orchestrator) will check for all six files before
proceeding to pynq_signal_process.
