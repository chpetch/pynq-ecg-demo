# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
iop_iic_test.py -- verify the AD7991-0 ADC via the MicroBlaze PMODB IOP that is
now embedded in OUR custom overlay (ps/ecg_demo.bit). This is the goal of the
MicroBlaze-IOP pivot: Pmod_IIC reads the chip from our own bitstream, not the
base overlay.

Run on the PYNQ-Z2 board (NOT the PC):
    sudo python3 /home/xilinx/pynq-ecg-demo/ps/iop_iic_test.py

Expected: iop_pmodb is listed, then CH0 reads ~4095 with CH0 tied to VCC (and
tracks the input if you change it / drive it from the DAC loopback).
"""

import os
from pynq import Overlay
from pynq.lib.pmod import Pmod_IIC

HERE = os.path.dirname(os.path.abspath(__file__))
BIT  = os.path.join(HERE, "ecg_demo.bit")   # ecg_demo.hwh must sit alongside

I2C_ADDR = 0x28   # AD7991-0 (ADDR pin tied to GND on PMOD AD2)
CFG_CH0  = 0x10   # config: enable CH0, Vcc reference, filter off

def main():
    print("Loading overlay:", BIT)
    ol = Overlay(BIT)
    print("  [OK] overlay loaded")

    if not hasattr(ol, "iop_pmodb"):
        print("  [FAIL] PYNQ did not bind iop_pmodb -- check pynq.__version__ is 3.0.x")
        return
    print("  [OK] iop_pmodb recognised as:", type(ol.iop_pmodb).__name__)
    # MicroblazeHierarchy exposes the mb_info dict that Pmod_IIC needs (passing
    # the hierarchy object itself raises 'not subscriptable').
    mb_info = ol.iop_pmodb.mb_info
    print("      mb_info:", mb_info)

    print("Init Pmod_IIC on PMODB pins 2(SCL/V10), 3(SDA/W10), addr 0x%02X" % I2C_ADDR)
    iic = Pmod_IIC(mb_info, 2, 3, I2C_ADDR)
    print("  [OK] Pmod_IIC initialised")

    print("Reading CH0 10x:")
    vals = []
    for i in range(10):
        iic.send([CFG_CH0])
        d = iic.receive(2)
        ch = (d[0] >> 4) & 0x3
        raw = ((d[0] & 0x0F) << 8) | d[1]
        vals.append(raw)
        print("    %2d  CH%d  raw=%4d  (%.3f V)" % (i, ch, raw, raw * 3.3 / 4096))

    mn, mx = min(vals), max(vals)
    print("\n  min=%d max=%d" % (mn, mx))
    if mx == 0:
        print("  [WARN] all zeros -- check ADDR=GND and SCL/SDA wiring")
    else:
        print("  [OK] AD7991 ACKs and returns data FROM THE CUSTOM OVERLAY.")
        print("       The MicroBlaze-IOP pivot works.")

if __name__ == "__main__":
    main()
