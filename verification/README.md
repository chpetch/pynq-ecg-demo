# Subsystem verification

On-hardware verification scripts for the PYNQ-Z2 ECG demo. These complement the
RTL simulations in `sim/` (cocotb) by exercising the real board: DAC output, ADC
read-back, and the full analog loopback datapath.

Bitstream used: `ps/ecg_demo.bit` (AXI-IIC build — AD7991-0 on JB **SCL=T11 / SDA=T10**).
Each board script finds the bitstream automatically (script dir → `../ps/` →
the deployed board path), or set `ECG_BIT=/path/to/ecg_demo.bit`.

| Script | Runs on | What it verifies |
|---|---|---|
| `verify_dac_adc.py` | board (root) | DAC sweeps ECG_DAC (DDS walking ROM) **and** AD7991 ACKs/returns CH0 data. PASS/FAIL summary. `--mmio` forces the raw-MMIO ADC path. |
| `capture_ecg_adc.py` | board (root) | Captures ~6 s of CH0 at ~367 Hz → `/home/xilinx/ecg_adc.{png,csv}`. Proves the full DDS→DAC→loopback→ADC chain. |
| `plot_ecg_csv.py` | PC | Re-plots a pulled `ecg_adc.csv` with matplotlib + a beat-count/BPM estimate. |

## Run on the board

Overlay load needs root **and** the PYNQ/XRT env sourced (else "No Devices Found"):

```bash
ssh xilinx@192.168.2.99 \
  "cd /home/xilinx/jupyter_notebooks/pynq-ecg-demo/verification && \
   sudo bash -c 'source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; \
                 python3 verify_dac_adc.py'"
```

Then for the ECG capture, pull and re-plot on the PC:

```powershell
scp xilinx@192.168.2.99:/home/xilinx/ecg_adc.csv captures/
py verification/plot_ecg_csv.py captures/ecg_adc.csv
```

Deploy these to the board with `ps/deploy.ps1 -BoardIP <ip>` (it copies both `ps/`
and `verification/`).

See `docs/lessons_learned.md` for the DAC/ADC debugging history behind these checks.
