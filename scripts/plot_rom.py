import re
import sys

rom_path = "pl/ecg_rom.v"

try:
    rom = open(rom_path).read()
except FileNotFoundError:
    print(f"ERROR: {rom_path} not found. Run from project root.")
    sys.exit(1)

vals = [int(x) for x in re.findall(r"12'd(\d+)", rom)][:360]

if not vals:
    print("ERROR: No 12'h values found in ecg_rom.v")
    sys.exit(1)

max_val = max(vals)
width = 60

print(f"ECG ROM — {len(vals)} samples, peak = {max_val} (0x{max_val:03X})")
print("-" * (width + 12))

for i, v in enumerate(vals):
    bar = "#" * int(v / max_val * width)
    print(f"{i:3d} | {v:4d} | {bar}")

print("-" * (width + 12))
print("Run from project root:  python scripts/plot_rom.py")
