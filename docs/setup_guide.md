# Setup Guide

End-to-end instructions for building, deploying, and running the PYNQ-Z2 ECG Demo.

---

## 1. Prerequisites

### Hardware

| Item | Notes |
|---|---|
| [PYNQ-Z2 board](https://www.tul.com.tw/productspynq-z2.html) | xc7z020clg400-1 |
| microSD card, 8 GB or larger | Class 10 / UHS-I recommended |
| PMOD DA4 (AD5628-1) | 8-channel 12-bit SPI DAC |
| PMOD AD2 | I²C 12-bit ADC (AD7991-0) |
| 2× jumper wires | DAC → ADC loopback + GND |
| Ethernet cable | Board to host or switch |
| USB Micro-B cable | 5 V power from PC or USB charger |

### Software

| Tool | Install command | Notes |
|---|---|---|
| Python 3.10+ | [python.org](https://www.python.org/downloads/) | Dashboard host |
| Vivado 2022.1+ WebPACK | [xilinx.com/vivado](https://www.xilinx.com/support/download.html) | Free; ~30 GB; requires registration at xilinx.com |
| PYNQ-Z2 board files | See Section 4a | Adds PYNQ-Z2 board to Vivado parts list |
| Balena Etcher | [etcher.balena.io](https://etcher.balena.io/) | Flash SD card |
| OpenSSH / `scp` | Pre-installed on Linux/macOS/Windows 10+ | Deploy files to board |

---

## 2. PYNQ Board Setup

1. Download the **PYNQ 3.0 image for PYNQ-Z2** from [pynq.io/board.html](http://www.pynq.io/board.html).
2. Flash the image to the microSD card with Balena Etcher.
3. Insert the SD card into the PYNQ-Z2 SD slot.
4. Set the boot jumper (JP4) to **SD**.
5. Connect an Ethernet cable between the board's RJ45 port and your PC or router.
6. Connect the USB Micro-B cable for power.
7. Wait ~60 s for boot (the green DONE LED lights when the PS is ready).

| Parameter | Default value |
|---|---|
| IP address | `192.168.2.99` |
| SSH user | `xilinx` |
| SSH / Jupyter password | `xilinx` |
| Jupyter URL | `http://192.168.2.99` |

> If using a static IP on your PC, set the Ethernet adapter to `192.168.2.x` (any host address other than `.99`) with subnet mask `255.255.255.0`.

---

## 3. Hardware Wiring

Full pin-level details are in `docs/wiring_guide.md`. Summary:

| Connection | From | To |
|---|---|---|
| PMOD DA4 (SPI DAC) | JA header pins 1, 2, 4 (CS, DIN, SCLK) | PMOD DA4 module |
| PMOD AD2 (I²C ADC) | JB header pins 1, 2 (SDA, SCL) | PMOD AD2 module |
| Loopback wire | PMOD DA4 VOUT Ch A | PMOD AD2 VIN+ |
| Common ground | PMOD DA4 GND | PMOD AD2 GND |

**Voltage note:** DAC output is 0–2.5 V. If the ADC full-scale input is below 2.5 V, add a 2:1 resistor divider (10 kΩ + 10 kΩ) between VOUT and VIN+. See `docs/wiring_guide.md` for details.

---

## 4. Vivado Project Setup

### 4a. Install PYNQ-Z2 Board Files

```bash
git clone https://github.com/cathalmccabe/pynq-z2_board_files.git
cp -r pynq-z2_board_files/pynq-z2 <Vivado_install>/data/boards/board_files/
```

Restart Vivado if it is already open.

### 4b. Run the TCL Build Script

Vivado WebPACK is free and does not require a licence for the xc7z020.

```bash
vivado -mode batch -source vivado/create_project.tcl
```

This script creates a project targeting `xc7z020clg400-1`, adds all `pl/*.v` RTL sources and `pl/constraints.xdc`, builds the block design (Zynq PS + AXI Interconnect + custom IPs), then runs synthesis, implementation, and bitstream generation.

Expected runtime: 10–20 minutes on a modern desktop.

### 4c. Expected Outputs

| File | Destination |
|---|---|
| `ecg_demo.bit` | `ps/ecg_demo.bit` |
| `ecg_demo.hwh` | `ps/ecg_demo.hwh` |

If the TCL script is unavailable, follow the manual block design steps in `docs/architecture.md` (Vivado Block Design section).

---

## 5. Deploy to Board

```bash
cd ps && ./deploy.sh 192.168.2.99
```

`deploy.sh` copies the entire `ps/` directory to `/home/xilinx/pynq-ecg-demo/ps/` on the board via `scp`. The default target IP is `192.168.2.99`; pass an alternative IP as the first argument.

---

## 6. Start Server

```bash
ssh xilinx@192.168.2.99
cd /home/xilinx/pynq-ecg-demo/ps
./start_server.sh
```

`start_server.sh` launches the FastAPI/uvicorn server on port 5000:

```bash
uvicorn server:app --host 0.0.0.0 --port 5000 --workers 1
```

The server loads the PYNQ overlay (`ecg_demo.bit` + `ecg_demo.hwh`), programs the FPGA fabric, and begins streaming ADC samples over WebSocket. Leave this SSH session open, or run under `tmux`/`screen`.

---

## 7. Run Dashboard

```bash
cd pc
pip install -r requirements.txt
./run_dashboard.sh
```

Open `http://localhost:8501` in a browser, enter the board IP (`192.168.2.99`), and click **Connect**.

Or run directly:

```bash
streamlit run dashboard.py --server.port 8501 --server.headless false
```

---

## 8. Verify End-to-End

| Check | Expected result |
|---|---|
| SSH to board succeeds | Prompt `xilinx@pynq:~$` |
| Server starts | `Uvicorn running on http://0.0.0.0:5000` in terminal |
| Dashboard connects | Status badge turns green |
| ECG waveform visible | Scrolling blue/grey/green overlaid traces on chart |
| BPM reading | Numeric value in top-right metric (~60 BPM at default) |
| Sliders respond | Moving Heart Rate slider and clicking **Apply Config** changes waveform frequency |
| R-peak markers | Red dots appear on the filtered trace at each QRS complex |
| REST health check | `curl http://192.168.2.99:5000/status` returns JSON with `"signal_present": true` |

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Cannot ping `192.168.2.99` | Host IP not on `192.168.2.x` subnet | Set PC Ethernet adapter to static IP `192.168.2.x`, mask `255.255.255.0` |
| DONE LED never lights | Bad SD image or wrong boot jumper | Re-flash SD with Balena Etcher; confirm JP4 is set to SD |
| `scp` fails — "Permission denied" | SSH key not trusted | Run `ssh-copy-id xilinx@192.168.2.99` (password: `xilinx`) |
| Overlay load error on server start | `.bit` or `.hwh` missing from `ps/` | Re-run `vivado/create_project.tcl`; confirm outputs land in `ps/` |
| Dashboard shows "Connection refused" | Server not running | SSH to board and run `./start_server.sh`; check port 5000 is not blocked by firewall |
| Flat waveform / BPM = 0 | Loopback wire disconnected | Connect DAC VOUT Ch A → ADC VIN+; verify common GND |
| Waveform clipped at top | No voltage divider | Add 10 kΩ + 10 kΩ divider between DAC VOUT and ADC VIN+ |
| Dashboard shows `⚠ Signal Lost` | `lead_off` bit set in STATUS register | Reseat PMOD AD2 in JB; check loopback wire |
| Vivado TCL script errors on board part | Board files not installed | Install PYNQ-Z2 board files (Section 4a) and retry |
| `pip install` fails | Python < 3.10 | Upgrade Python; `streamlit>=1.32` requires 3.8+ minimum, 3.10 recommended |

---

_Last updated: Milestone 7 — GUI Dashboard_
