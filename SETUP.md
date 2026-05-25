# SETUP.md — Free Toolchain Install Guide

## What You Need

| Tool | Purpose | Cost |
|---|---|---|
| Vivado 2023.2 Webpack | FPGA synthesis + bitstream | Free (AMD account) |
| PYNQ 3.0 image | Board OS | Free |
| Icarus Verilog | RTL simulation | Free |
| cocotb | Python testbench framework | Free |
| GTKWave | Waveform viewer | Free |
| Python 3.10+ | All scripting | Free |
| Claude Code | Claude agents (orchestrator, RTL, algo, sim) | Claude subscription |
| Aider | Gemini agents (PS server, GUI, docs) | Free tool |
| Gemini API key | Gemini 2.5 Pro via Aider | Google AI Pro subscription |

---

## 1. Vivado 2023.2 Webpack

Free tier fully supports xc7z020 (PYNQ-Z2). No license file needed.

1. Create a free AMD account at `amd.com`
2. Download **Vivado ML Edition 2023.2** from AMD downloads page
3. Run installer, select **Vivado ML Standard** (free tier)
4. Under devices, ensure **Zynq-7000** is checked
5. Install PYNQ-Z2 board files:

```bash
# Download board files
git clone https://github.com/Xilinx/XilinxBoardStore.git
# Copy to Vivado board directory
cp -r XilinxBoardStore/boards/Xilinx/pynqz2 \
  ~/tools/Xilinx/Vivado/2023.2/data/boards/board_files/
```

Verify: open Vivado → New Project → select **pynq-z2** from board list.

---

## 2. PYNQ 3.0 Board Image

1. Download `pynq_z2_v3.0.1.img.zip` from `pynq.io/board.html`
2. Flash to a 16GB+ microSD card:

```bash
# Linux / macOS
unzip pynq_z2_v3.0.1.img.zip
sudo dd if=pynq_z2_v3.0.1.img of=/dev/sdX bs=4M status=progress

# Windows: use Balena Etcher (free)
```

3. Insert SD card, connect Ethernet, power on
4. Default IP: `192.168.2.99`  Default password: `xilinx`
5. Verify: open browser → `http://192.168.2.99:9090/lab` → Jupyter loads

---

## 3. Simulation Toolchain (Linux / macOS / WSL)

```bash
# Icarus Verilog
sudo apt install iverilog          # Ubuntu/Debian
brew install icarus-verilog        # macOS

# GTKWave
sudo apt install gtkwave           # Ubuntu/Debian
brew install --cask gtkwave        # macOS

# Python packages for simulation
pip install cocotb cocotb-bus
pip install numpy scipy matplotlib neurokit2

# Verify
iverilog -V                        # should print version
python3 -c "import cocotb; print('cocotb ok')"
```

---

## 4. Claude Code (for Claude agents)

```bash
# Requires Node.js 18+
node --version                     # check first

npm install -g @anthropic-ai/claude-code

# Verify
claude --version
```

Sign in with your Claude subscription account on first run.

---

## 5. Antigravity CLI (for Gemini agents)

```powershell
# Install via official installer (PowerShell)
irm https://antigravity.google/cli/install.ps1 | iex

# Sign in with your Google account
agy auth login

# Verify
agy --version
```

---

## 6. Project Python Dependencies (PC side)

```bash
pip install streamlit plotly websockets requests fastapi uvicorn
```

---

## 7. Recommended .claudeignore Templates

Save these and swap them when switching agent sessions.

**`scripts/ignore_for_gen.txt`** (use when running pynq_ecg_gen):
```
sim/
ps/
pc/
docs/
algo/
```

**`scripts/ignore_for_process.txt`** (use when running pynq_ecg_process):
```
sim/
ps/
pc/
docs/
```

**`scripts/ignore_for_sim.txt`** (use when running pynq_simulation):
```
ps/
pc/
docs/
```

**`scripts/ignore_for_ps.txt`** (use when running pynq_ps_server):
```
pl/
sim/
pc/
algo/
```

**`scripts/ignore_for_gui.txt`** (use when running pynq_gui):
```
pl/
sim/
ps/
algo/
```

Swap with:
```bash
cp scripts/ignore_for_gen.txt .claudeignore
```

---

## 8. Verify Everything

```bash
# Run this checklist before starting
echo "=== Toolchain Check ==="
iverilog -V 2>&1 | head -1
python3 -c "import cocotb" && echo "cocotb ok"
python3 -c "import numpy, scipy, neurokit2" && echo "Python DSP ok"
python3 -c "import streamlit, plotly, websockets" && echo "GUI stack ok"
claude --version
aider --version
echo "=== All checks done ==="
```

---

## 9. Folder Initialisation

```bash
git clone <your-repo> pynq-ecg-demo   # or mkdir pynq-ecg-demo
cd pynq-ecg-demo

# Create folder structure
mkdir -p agents handoffs algo pl sim ps pc docs scripts

# Copy agent prompts into agents/
# (download from wherever you stored them)

# Start orchestrator
claude
```

---

## Quick Reference

| Action | Command |
|---|---|
| Start Claude agent session | `claude` |
| Start Gemini agent session | `agy` |
| Run all simulations | `cd sim && ./run_all.sh` |
| Deploy PS server to board | `cd ps && ./deploy.sh 192.168.2.99` |
| Start dashboard | `cd pc && ./run_dashboard.sh` |
| View waveform | `gtkwave sim/results/<module>.vcd` |
| Compact Claude context | `/compact` (inside Claude Code session) |
