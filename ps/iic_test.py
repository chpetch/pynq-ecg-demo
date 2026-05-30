# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
iic_test.py -- verify the AD7991-0 ADC via the Xilinx AXI IIC IP in OUR custom
overlay (ps/ecg_demo.bit, AXI-IIC build). This is the lightweight alternative to
the MicroBlaze-IOP overlay: no soft CPU, just an AXI IIC core read from the PS.

Run on the PYNQ-Z2 board (NOT the PC):
    sudo python3 .../ps/iic_test.py            # uses pynq AxiIIC driver
    sudo python3 .../ps/iic_test.py --mmio     # raw MMIO fallback (if bind fails)

Expected: CH0 ~= 4095 (3.3 V) with CH0 tied to VCC; tracks the input; ~0 when the
CH0 line is open. Matches the IOP build's result.
"""

import os
import sys
import time
from pynq import Overlay, MMIO

HERE = os.path.dirname(os.path.abspath(__file__))
BIT  = os.path.join(HERE, "ecg_demo.bit")   # ecg_demo.hwh must sit alongside

I2C_ADDR  = 0x28   # AD7991-0
CFG_CH0   = 0x10   # config: enable CH0, Vcc reference, no filter
IIC_BASE  = 0x41600000

def read_pynq(ol, n=10):
    """Primary path: pynq AxiIIC driver (overlay.axi_iic_0)."""
    if not hasattr(ol, "axi_iic_0"):
        print("  [FAIL] overlay has no axi_iic_0 -- try --mmio, or check ip_dict:",
              list(ol.ip_dict.keys()))
        return None
    iic = ol.axi_iic_0
    print("  [OK] axi_iic_0 bound:", type(iic).__name__)
    vals = []
    for i in range(n):
        iic.send(I2C_ADDR, [CFG_CH0], 1)
        d = iic.receive(I2C_ADDR, 2)
        ch  = (d[0] >> 4) & 0x3
        raw = ((d[0] & 0x0F) << 8) | d[1]
        vals.append(raw)
        print("    %2d  CH%d  raw=%4d  (%.3f V)" % (i, ch, raw, raw * 3.3 / 4096))
        time.sleep(0.02)
    return vals

def read_mmio(n=10):
    """Fallback: raw AXI IIC dynamic-mode read (register map per PG090 /
    handoffs/milestone_log.md). TX_FIFO entry = (STOP<<9)|(START<<8)|data."""
    iic = MMIO(IIC_BASE, 0x10000)
    CR, SR, TX, RX, SOFTR = 0x100, 0x104, 0x108, 0x10C, 0x40
    vals = []
    for i in range(n):
        iic.write(SOFTR, 0x0A)              # soft reset
        time.sleep(0.001)
        iic.write(CR, 0x02)                 # reset TX FIFO
        iic.write(CR, 0x01)                 # enable
        # write config: START+addr(W), STOP+0x10
        iic.write(TX, 0x100 | (I2C_ADDR << 1))        # START + 0x50
        iic.write(TX, 0x200 | CFG_CH0)                # STOP  + 0x10
        time.sleep(0.001)
        # read 2 bytes: START+addr(R), then STOP+count(2)
        iic.write(TX, 0x100 | (I2C_ADDR << 1) | 1)    # START + 0x51
        iic.write(TX, 0x200 | 0x02)                   # STOP  + read count 2
        # wait for RX FIFO to fill, then drain 2 bytes
        deadline = time.time() + 0.05
        b = []
        while len(b) < 2 and time.time() < deadline:
            if not (iic.read(SR) & 0x40):    # RX_FIFO_EMPTY clear -> data present
                b.append(iic.read(RX) & 0xFF)
        if len(b) < 2:
            print("    %2d  [timeout] SR=0x%02X" % (i, iic.read(SR)))
            continue
        raw = ((b[0] & 0x0F) << 8) | b[1]
        vals.append(raw)
        print("    %2d  raw=%4d  (%.3f V)" % (i, raw, raw * 3.3 / 4096))
        time.sleep(0.02)
    return vals

def main():
    use_mmio = "--mmio" in sys.argv
    print("Loading overlay:", BIT)
    ol = Overlay(BIT)
    print("  [OK] overlay loaded")
    print("Reading AD7991 CH0 (addr 0x%02X) via %s:" % (
        I2C_ADDR, "raw MMIO" if use_mmio else "pynq AxiIIC"))
    vals = read_mmio() if use_mmio else read_pynq(ol)
    if not vals:
        print("  [FAIL] no samples")
        return
    mn, mx = min(vals), max(vals)
    print("\n  min=%d max=%d" % (mn, mx))
    if mx == 0:
        print("  [WARN] all zeros -- check ADDR=GND / CH0 wiring")
    else:
        print("  [OK] AD7991 ACKs and returns data via the AXI IIC IP. Done.")

if __name__ == "__main__":
    main()
