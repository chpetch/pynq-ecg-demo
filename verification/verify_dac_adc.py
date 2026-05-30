# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
verify_dac_adc.py -- subsystem verification: DAC + ADC bring-up on the AXI-IIC
build of ecg_demo.bit (AD7991-0 on JB SCL=T11 / SDA=T10).

Run ON THE BOARD as root (overlay load needs FPGA access):
    sudo bash -c 'source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; \
        python3 verification/verify_dac_adc.py'
    ... verify_dac_adc.py --mmio     # force raw-MMIO ADC path

PASS criteria:
  DAC : ECG_DAC (0x40) sweeps a wide range as the DDS walks the ROM.
  ADC : AD7991 ACKs and returns CH0 data via the AXI IIC core.
"""

import os
import sys
import time
from pynq import Overlay, MMIO

# --- custom AXI-Lite register block (ecg_process_top) ---
BASE_ADDR   = 0x43C00000
MAP_SIZE    = 0x44
REG_ECG_RAW = 0x28
REG_BPM_OUT = 0x30
REG_STATUS  = 0x3C
REG_ECG_DAC = 0x40
N_DAC       = 720          # ~2 s at 360 Hz
DAC_DT      = 1.0 / 360

# --- AD7991-0 via Xilinx AXI IIC IP ---
I2C_ADDR  = 0x28
CFG_CH0   = 0x10
IIC_BASE  = 0x41600000


def find_bitstream():
    """Locate ecg_demo.bit regardless of where this script is run from."""
    cands = []
    if os.environ.get("ECG_BIT"):
        cands.append(os.environ["ECG_BIT"])
    here = os.path.dirname(os.path.abspath(__file__))
    cands += [
        os.path.join(here, "ecg_demo.bit"),
        os.path.join(here, "..", "ps", "ecg_demo.bit"),
        "/home/xilinx/jupyter_notebooks/pynq-ecg-demo/ps/ecg_demo.bit",
    ]
    for c in cands:
        if os.path.exists(c):
            return os.path.abspath(c)
    raise FileNotFoundError("ecg_demo.bit not found; tried:\n  " + "\n  ".join(cands))


def test_dac(ol):
    print("\n[DAC] sampling ECG_DAC (0x40) for ~2 s ...")
    mmio = MMIO(BASE_ADDR, MAP_SIZE)
    vals = [mmio.read(REG_ECG_DAC) & 0xFFF for _ in _rate_loop(N_DAC, DAC_DT)]
    mn, mx = min(vals), max(vals)
    rng = mx - mn
    print("  ECG_DAC: min=0x%03X max=0x%03X range=%d" % (mn, mx, rng))
    print("  BPM_OUT=%d  STATUS=0b%s" % (mmio.read(REG_BPM_OUT) & 0xFF,
                                          format(mmio.read(REG_STATUS) & 0x3, "02b")))
    ok = rng >= 10
    print("  [%s] DAC %s" % ("PASS" if ok else "FAIL",
          "sweeps %d counts -- DDS is walking the ROM" % rng if ok
          else "is flat -- DDS frozen / bitstream missing fix"))
    return ok


def _rate_loop(n, dt):
    for _ in range(n):
        yield
        time.sleep(dt)


def adc_pynq(ol, n=10):
    if not hasattr(ol, "axi_iic_0"):
        print("  axi_iic_0 NOT in ip_dict:", list(ol.ip_dict.keys()))
        return None
    iic = ol.axi_iic_0
    print("  axi_iic_0 bound:", type(iic).__name__)
    vals = []
    for i in range(n):
        try:
            iic.send(I2C_ADDR, [CFG_CH0], 1)
            d = iic.receive(I2C_ADDR, 2)
        except Exception as e:
            print("    %2d  [err] %s" % (i, e))
            return None
        raw = ((d[0] & 0x0F) << 8) | d[1]
        vals.append(raw)
        print("    %2d  CH%d raw=%4d (%.3f V)" %
              (i, (d[0] >> 4) & 0x3, raw, raw * 3.3 / 4096))
        time.sleep(0.02)
    return vals


def adc_mmio(n=10):
    iic = MMIO(IIC_BASE, 0x10000)
    CR, SR, TX, RX, SOFTR = 0x100, 0x104, 0x108, 0x10C, 0x40
    vals = []
    for i in range(n):
        iic.write(SOFTR, 0x0A); time.sleep(0.001)
        iic.write(CR, 0x02); iic.write(CR, 0x01)
        iic.write(TX, 0x100 | (I2C_ADDR << 1))     # START + addr(W)
        iic.write(TX, 0x200 | CFG_CH0)             # STOP  + config
        time.sleep(0.001)
        iic.write(TX, 0x100 | (I2C_ADDR << 1) | 1) # START + addr(R)
        iic.write(TX, 0x200 | 0x02)                # STOP  + read 2
        deadline = time.time() + 0.05
        b = []
        while len(b) < 2 and time.time() < deadline:
            if not (iic.read(SR) & 0x40):
                b.append(iic.read(RX) & 0xFF)
        if len(b) < 2:
            print("    %2d  [timeout] SR=0x%02X" % (i, iic.read(SR)))
            continue
        raw = ((b[0] & 0x0F) << 8) | b[1]
        vals.append(raw)
        print("    %2d  raw=%4d (%.3f V)" % (i, raw, raw * 3.3 / 4096))
        time.sleep(0.02)
    return vals


def test_adc(ol, force_mmio):
    print("\n[ADC] reading AD7991 CH0 (0x%02X) via %s ..." %
          (I2C_ADDR, "raw MMIO" if force_mmio else "pynq AxiIIC (MMIO fallback)"))
    vals = adc_mmio() if force_mmio else (adc_pynq(ol) or adc_mmio())
    if not vals:
        print("  [FAIL] no samples -- AD7991 never ACKed")
        return False
    mn, mx = min(vals), max(vals)
    print("  min=%d max=%d" % (mn, mx))
    ok = mx > 0
    print("  [%s] ADC %s" % ("PASS" if ok else "WARN",
          "AD7991 ACKs and returns data via AXI IIC" if ok
          else "all zeros -- check ADDR/GND and CH0 wiring"))
    return ok


def main():
    force_mmio = "--mmio" in sys.argv
    bit = find_bitstream()
    print("Loading overlay:", bit)
    ol = Overlay(bit)
    print("  [OK] overlay loaded")
    dac_ok = test_dac(ol)
    adc_ok = test_adc(ol, force_mmio)
    print("\n=== SUMMARY ===")
    print("  DAC: %s" % ("PASS" if dac_ok else "FAIL"))
    print("  ADC: %s" % ("PASS" if adc_ok else "FAIL"))
    sys.exit(0 if (dac_ok and adc_ok) else 1)


if __name__ == "__main__":
    main()
