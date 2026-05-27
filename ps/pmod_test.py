# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
pmod_test.py -- PMOD DA4 (AD5628-1 SPI DAC) + PMOD AD2 (AD7991-0 I2C ADC) test.

Uses the PYNQ BASE overlay (replaces any custom overlay while this test runs).
The base overlay ships with PYNQ 2.5 and provides MicroBlaze IOPs on every
PMOD header that implement GPIO, SPI, and I2C.

Wiring required:
  PMOD DA4  -> JA header      (CS=JA1, DIN=JA2, SCLK=JA4 -- JA3 not used)
  PMOD AD2  -> JB RIGHT half  (SCL=JB3/V10, SDA=JB4/W10)
  Jumper    -> DA4 VOUT_A  ->  AD2 CH0  (loopback; required for Section 4)

Run:
  python3 pmod_test.py        # from SSH / JupyterLab terminal
  # or paste sections into notebook cells
"""

import time
import numpy as np
from pynq.overlays.base import BaseOverlay
from pynq.lib.pmod import Pmod_IO, Pmod_IIC, PMODA, PMODB

def hdr(title):
    print("")
    print("=" * 55)
    print("  " + title)
    print("=" * 55)

# =============================================================================
# 1. Load PYNQ base overlay
# =============================================================================
hdr("1. Load base overlay")

base = BaseOverlay("base.bit")
print("  [OK] Base overlay loaded (FPGA programmed with base design)")

# =============================================================================
# 2. PMOD DA4 -- SPI DAC test (AD5628-1)
#    Protocol: CPOL=1, CPHA=0 -- SCLK idles HIGH, data captured on FALLING edge
# =============================================================================
hdr("2. PMOD DA4 (AD5628-1) -- SPI test")

# Three separate Pmod_IO on PMODA share the same GPIO MicroBlaze firmware.
# Creating them in sequence is safe; the firmware is only loaded once.
cs   = Pmod_IO(PMODA, 0, 'out')   # JA[0] / JA1 -- CS_N (active low)
mosi = Pmod_IO(PMODA, 1, 'out')   # JA[1] / JA2 -- DIN
sclk = Pmod_IO(PMODA, 3, 'out')   # JA[3] / JA4 -- SCLK  (JA[2] unused)

# Idle state: CS high, SCLK high
cs.write(1)
sclk.write(1)

def spi_write32(word):
    """Send a 32-bit word MSB-first to the AD5628-1."""
    cs.write(0)
    for bit_pos in range(31, -1, -1):
        mosi.write((word >> bit_pos) & 1)
        sclk.write(0)   # falling edge -- AD5628 samples DIN here
        sclk.write(1)   # rising edge
    cs.write(1)         # rising CS latches the command into the DAC

def dac_set(channel, value):
    """Write and update DAC channel (0=A ... 7=H) to a 12-bit value (0-4095).

    AD5628-1 command word format (32 bits):
      [31:28] = 0000         (must be 0)
      [27:24] = 0011         (command 3: Write to and update DAC register)
      [23:20] = ch[3:0]      (channel address)
      [19:8]  = value[11:0]  (12-bit DAC code)
      [7:0]   = 0x00         (don't care)
    """
    word = (0x3 << 24) | ((channel & 0xF) << 20) | ((value & 0xFFF) << 8)
    spi_write32(word)

# Power-on: the AD5628-1 internal 2.5 V reference is disabled at reset.
# Command 8 (Internal Reference Setup Register), feature bit 0 = 1 -> enable.
print("  Enabling AD5628-1 internal 2.5 V reference...")
spi_write32(0x08000001)
time.sleep(0.01)

# Step channel A through known codes
print("  Writing test codes to channel A:")
print("    {:>5}  {:>10}".format("Code", "Expected V"))
print("    " + "-" * 20)
test_codes = [0, 1024, 2048, 3072, 4095]
for code in test_codes:
    dac_set(0, code)
    expected_v = code * 2.5 / 4095
    print("    {:>5d}  {:>8.3f} V".format(code, expected_v))
    time.sleep(0.05)

print("  [OK] SPI writes completed without error")
print("    (Use a multimeter on PMOD DA4 VOUT_A to confirm if no loopback wire.)")

# =============================================================================
# 3. PMOD AD2 -- I2C ADC test (AD7991-0)
#    PMOD AD2 is in JB RIGHT half: SCL=JB3 (pin index 2), SDA=JB4 (pin index 3)
#    AD7991-0 I2C address: 0x28  (ADDR pin tied to GND on PMOD AD2)
# =============================================================================
hdr("3. PMOD AD2 (AD7991-0) -- I2C test")
print("  Interface: PMODB  scl_pin=2 (JB3/V10)  sda_pin=3 (JB4/W10)  addr=0x28")

iic = None
try:
    # PYNQ 2.5 Pmod_IIC(if_id, scl_pin, sda_pin, iic_freq)
    # PYNQ 2.5 Pmod_IIC(if_id, scl_pin, sda_pin, iic_addr)
    # Address is bound at construction; send/receive do NOT take an address arg.
    iic = Pmod_IIC(PMODB, 2, 3, 0x28)
    print("  [OK] I2C driver initialised (AD7991-0 @ 0x28)")
except Exception as exc:
    print("  [FAIL] Could not init I2C: {}".format(exc))
    print("    Check: PMOD AD2 is in JB RIGHT half (JB3/JB4), not left half.")

def adc_read_ch0():
    """Read one 12-bit sample from AD7991-0 channel 0.

    AD7991-0 I2C protocol:
      Write config byte 0x10 (= CH0 enable, filter off, Vcc reference)
      Read back 2 bytes:
        byte[0] = [0][0][0][0][CHID1][CHID0][D11][D10]
        byte[1] = [D9][D8][D7][D6][D5][D4][D3][D2]
      12-bit result = ((byte[0] & 0x0F) << 8) | byte[1]

    PYNQ 2.5 Pmod_IIC API (address bound in constructor):
      send(data_list, length, option=0)
      receive(length, option=0)  -> list of bytes
    """
    iic.send([0x10])          # configure: CH0 only
    time.sleep(0.001)
    d = iic.receive(2)        # read conversion result
    ch_id = (d[0] >> 4) & 0x3
    raw   = ((d[0] & 0x0F) << 8) | d[1]
    return ch_id, raw

if iic is not None:
    N = 10
    print("  Reading {} samples from CH0:".format(N))
    print("    {:>3}  {:>2}  {:>5}  {:>8}".format("#", "CH", "Raw", "Voltage"))
    print("    " + "-" * 25)
    readings = []
    adc_ok = True
    for i in range(N):
        try:
            ch_id, raw = adc_read_ch0()
            voltage = raw * 3.3 / 4096
            readings.append(raw)
            print("    {:>3d}  CH{}  {:>5d}  {:>6.3f} V".format(i, ch_id, raw, voltage))
            time.sleep(0.02)
        except Exception as exc:
            print("    {:>3d}  [FAIL] I2C error: {}".format(i, exc))
            adc_ok = False
            break

    if adc_ok and readings:
        mn   = min(readings)
        mx   = max(readings)
        mean = float(np.mean(readings))
        std  = float(np.std(readings))
        print("")
        print("  Stats:  min={}  max={}  mean={:.1f}  sigma={:.1f}".format(mn, mx, mean, std))

        if mx == 0:
            print("  [WARN] All zeros -- check SCL/SDA wiring and ADDR pin is GND.")
        elif mx - mn < 3:
            print("  [OK] Very stable reading (expected for constant DC input).")
        else:
            print("  [OK] ADC responding with non-zero values.")

# =============================================================================
# 4. Loopback sweep -- DAC output feeds ADC input
#    Step DAC 0 -> 4095 and verify ADC tracks monotonically.
#    Expected ADC raw ~= DAC_code * (2.5 / 3.3)
# =============================================================================
hdr("4. Loopback sweep  (DA4 VOUT_A -> AD2 CH0)")

if iic is None:
    print("  Skipped -- I2C not available.")
else:
    sweep_codes = [0, 512, 1024, 1536, 2048, 2560, 3072, 3584, 4095]
    print("  {:>8}  {:>6}  |  {:>7}  {:>6}  {:>12}".format(
        "DAC code", "DAC V", "ADC raw", "ADC V", "Expected ADC"))
    print("  " + "-" * 50)

    prev_adc  = None
    monotonic = True
    results   = []

    for code in sweep_codes:
        dac_set(0, code)
        time.sleep(0.1)           # allow DAC output to settle
        try:
            _, adc_raw = adc_read_ch0()
            dac_v   = code    * 2.5 / 4095
            adc_v   = adc_raw * 3.3 / 4096
            exp_adc = int(code * 2.5 / 3.3)
            print("  {:>8d}  {:>5.3f}V  |  {:>7d}  {:>5.3f}V  {:>12d}".format(
                code, dac_v, adc_raw, adc_v, exp_adc))
            results.append((code, adc_raw))
            if prev_adc is not None and code > 0 and adc_raw < prev_adc - 50:
                monotonic = False
            prev_adc = adc_raw
        except Exception as exc:
            print("  {:>8d}  [FAIL] error: {}".format(code, exc))
            monotonic = False

    # Reset DAC to 0 V
    dac_set(0, 0)
    print("")

    if not results:
        print("  [WARN] No results collected.")
    elif monotonic and len(results) > 1 and results[-1][1] > results[0][1]:
        print("  [PASS] ADC tracks DAC monotonically. Both PMODs are working.")
    else:
        print("  [FAIL] Non-monotonic or flat response. Check:")
        print("     - Loopback jumper: DA4 VOUT_A -> AD2 CH0")
        print("     - Common GND between DA4 and AD2")
        print("     - PMOD AD2 is in JB RIGHT half (JB3/JB4)")
        print("     - Multimeter on VOUT_A during sweep to isolate DAC vs ADC fault")

# =============================================================================
print("")
print("=" * 55)
print("  Test complete.")
print("  To reload the ECG custom bitstream:")
print("    from pynq import Overlay")
print("    ol = Overlay('/home/xilinx/pynq-ecg-demo/ps/ecg_demo.bit')")
print("=" * 55)
