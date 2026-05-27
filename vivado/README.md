# Vivado Synthesis — PYNQ-Z2 ECG Demo

Generates the FPGA bitstream (`ps/ecg_demo.bit`) and hardware handoff (`ps/ecg_demo.hwh`) needed to load the PL design on the PYNQ-Z2 board.

---

## Prerequisites

| Item | Notes |
|---|---|
| Vivado 2022.1+ (WebPACK edition) | Free — register at [xilinx.com/products/design-tools/vivado](https://www.xilinx.com/products/design-tools/vivado.html), ~30 GB install |
| PYNQ-Z2 board files | See install steps below |
| Windows or Linux host | TCL script is OS-agnostic (no hardcoded paths) |

### Install PYNQ-Z2 board files

1. Download from [github.com/Xilinx/XilinxBoardStore](https://github.com/Xilinx/XilinxBoardStore)
2. Copy `boards/Xilinx/pynq-z2/` to:
   - **Windows:** `C:\Xilinx\Vivado\2022.1\data\boards\board_files\pynq-z2\`
   - **Linux:** `~/.Xilinx/Vivado/2022.1/data/boards/board_files/pynq-z2/`
3. Restart Vivado if it is already open

Alternative: in Vivado, go to **Tools → Settings → Board Repository** and add the `XilinxBoardStore` directory.

---

## How to Run

Run from the **repo root** (not from inside `vivado/`):

```bash
# Windows (add Vivado to PATH first, or use the full path)
vivado -mode batch -source vivado/create_project.tcl

# Linux
vivado -mode batch -source vivado/create_project.tcl
```

To add Vivado to PATH on Windows (run once per terminal session):
```cmd
set PATH=C:\Xilinx\Vivado\2022.1\bin;%PATH%
```

---

## Expected Runtime

| Step | Time |
|---|---|
| Project creation + block design | ~2 minutes |
| Synthesis | ~10 minutes |
| Implementation + routing | ~15 minutes |
| Bitstream write | ~2 minutes |
| **Total** | **~30 minutes** |

Times are for a modern laptop (4-core, 16 GB RAM). The script uses `-jobs 4`.

---

## Expected Output

The script prints `INFO:` lines before each step. A successful run ends with:

```
INFO: ============================================================
INFO: BUILD COMPLETE
INFO: Bitstream: ps/ecg_demo.bit
INFO: HWH file:  ps/ecg_demo.hwh
INFO: Run ps/deploy.sh <board_ip> to copy to the PYNQ-Z2 board
INFO: ============================================================
```

Build files land in `vivado/build/` (git-ignored). The two important outputs are copied to `ps/`:

| File | Size | Purpose |
|---|---|---|
| `ps/ecg_demo.bit` | ~2 MB | FPGA bitstream — loaded by PYNQ `Overlay()` |
| `ps/ecg_demo.hwh` | ~50 KB | Hardware handoff XML — tells PYNQ the AXI register map |

---

## Verification

```bash
# File exists and is ~2 MB
ls -lh ps/ecg_demo.bit   # expect: 2.0M – 2.5M
ls -lh ps/ecg_demo.hwh   # expect: 30K – 80K

# Check AXI base address appears in HWH
grep -o "43C00000" ps/ecg_demo.hwh
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ERROR: [Board 49-26] Part … not found` | Board files not installed | Install PYNQ-Z2 board files (see above) |
| `ERROR: [BD 5-216] VLNV … not found` | IP catalog not loaded | Open Vivado GUI once to trigger IP scan, then re-run batch |
| `ERROR: Synthesis failed` | RTL error in pl/*.v | Run `iverilog -t null -g2012 pl/*.v` in WSL to find issues |
| `ERROR: Implementation failed` | Timing / routing failure | Check `vivado/build/ecg_demo.runs/impl_1/runme.log` for details |
| `ERROR: HWH file not found` | Vivado path changed in newer version | Check `vivado/build/ecg_demo.srcs/` for the actual `.hwh` path |
| Script hangs at `wait_on_run` | Synthesis/impl crashed silently | Open `vivado/build/ecg_demo.runs/synth_1/runme.log` |
| Board part `tul.com.tw:pynq-z2:part0:1.0` not found | Older board file version | Try `xilinx.com:pynq-z2:part0:1.0` in the TCL (line 14) |

---

_Last updated: Milestone 6 — Vivado Synthesis_
