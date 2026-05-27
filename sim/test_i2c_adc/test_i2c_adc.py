"""
test_i2c_adc.py — cocotb testbench for i2c_adc_driver
3 test cases as specified in agents/pynq_simulation.md

RTL notes:
- CLK_DIV=124 → half-period=125 clocks → full SCL period=250 clocks (400 kHz at 100 MHz)
- I2C_ADDR=0x28, CFG_BYTE=0x10
- adc_sda is inout: assign adc_sda = sda_oe ? sda_out : 1'bz
- During READ bit phases: RTL tristates SDA (sda_oe=0), testbench drives bits

STATE-BASED APPROACH: monitor RTL internal state register directly.
This avoids counting SCL edges (which is error-prone due to non-bit SCL events
like START and REP_START consuming extra fall/rise events).

RTL state constants:
  RD_ADDR_ACK  = 13
  RD_BYTE1_BIT = 14
  RD_BYTE1_ACK = 15
  RD_BYTE2_BIT = 16

ACK timing: when state=ACK and phase=0, scl_r is immediately set HIGH.
The RTL does NOT sample sda_in during ACK (just proceeds). So any time
SDA=0 while SCL is high in the ACK slot is fine.

READ_BIT sampling: RTL samples sda_in at half_tick of phase=0 (125 clocks
after SCL goes HIGH). Testbench must drive SDA BEFORE SCL rises.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.types import LogicArray

CLK_PERIOD_NS = 10
HALF_PERIOD = 125
Z_VAL = LogicArray('Z')

# RTL state constants
RD_ADDR_ACK  = 13
RD_BYTE1_BIT = 14
RD_BYTE1_ACK = 15
RD_BYTE2_BIT = 16


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.adc_sda.value = Z_VAL
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


def scl_val(dut):
    return int(dut.adc_scl.value)


def get_state(dut):
    try:
        return int(dut.state.value)
    except Exception:
        return -1


async def wait_scl_fall(dut, timeout=2000):
    prev = scl_val(dut)
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        cur = scl_val(dut)
        if prev == 1 and cur == 0:
            return True
        prev = cur
    return False


async def wait_scl_rise(dut, timeout=2000):
    prev = scl_val(dut)
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        cur = scl_val(dut)
        if prev == 0 and cur == 1:
            return True
        prev = cur
    return False


async def wait_for_state(dut, target_state, timeout=5000):
    """Wait until RTL enters the specified state."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if get_state(dut) == target_state:
            return True
    return False


async def drive_read_byte_in_state(dut, byte_val, read_state, timeout=5000):
    """Drive 8 bits for a READ_BIT state.

    Waits for the RTL to enter read_state (e.g. RD_BYTE1_BIT=14).
    At entry to read_state, phase=0, SCL is about to go HIGH (next clock).

    For each of the 8 bits:
      - drive bit BEFORE SCL rises
      - wait for SCL rise (phase=0)
      - hold through SCL high (RTL samples at half_tick)
      - wait for SCL fall (phase=1)

    Returns when all 8 bits driven and SCL has fallen for the last bit
    (leaving us at the start of the ACK slot).
    """
    # Wait for RTL to enter the read state
    ok = await wait_for_state(dut, read_state, timeout)
    assert ok, f"RTL never entered state {read_state}"

    bits = [(byte_val >> (7 - i)) & 1 for i in range(8)]

    for bit_val in bits:
        # SCL is LOW (phase=0, about to rise on next clock or has just entered state)
        dut.adc_sda.value = bit_val
        ok = await wait_scl_rise(dut)
        assert ok, f"SCL didn't rise for read bit"
        # Hold through SCL high (RTL samples at half_tick ~125 clocks in)
        ok = await wait_scl_fall(dut)
        assert ok, f"SCL didn't fall after read bit"
    # After 8 bits, SCL just fell for bit 0's phase=1 → ACK slot starts
    dut.adc_sda.value = Z_VAL


async def i2c_slave_respond(dut, byte1=0x05, byte2=0xA3):
    """
    Full I2C slave response for i2c_adc_driver transaction.

    Uses state-based monitoring (dut.state) instead of counting SCL edges.

    Transaction flow:
      1. Wait for START (sda_oe=1, sda_out=0, scl=1)
      2. Skip write address + ACK by waiting for RD_ADDR_ACK state
         (the write address ACK is handled by driving SDA=0 when the RTL
         is in WR_ADDR_ACK or WR_CFG_ACK — but since RTL ignores the
         value and just checks sda_in==0, we drive 0 whenever SCL is HIGH
         and sda_oe=0, which naturally covers both ACK slots)
      3. Wait for RD_ADDR_ACK: drive SDA=0 during SCL high, wait for SCL fall
      4. Drive byte1 when RTL enters RD_BYTE1_BIT
      5. Wait for RD_BYTE1_ACK: RTL drives SDA=0 (master ACK), we skip
      6. Drive byte2 when RTL enters RD_BYTE2_BIT
      7. RTL drives NACK, STOP, pulses adc_valid

    For write ACKs (WR_ADDR_ACK and WR_CFG_ACK):
      The RTL has sda_oe=0 during these slots. We drive SDA=0 continuously
      until the read phase begins.
    """
    dut.adc_sda.value = Z_VAL

    # --- Step 1: Wait for START condition ---
    found = False
    for _ in range(5000):
        await RisingEdge(dut.clk)
        try:
            oe = int(dut.sda_oe.value)
            so = int(dut.sda_out.value)
        except Exception:
            continue
        if scl_val(dut) == 1 and oe == 1 and so == 0:
            found = True
            break
    assert found, "Slave: never saw START"

    # --- Step 2 & 3: Drive ACK during WR_ADDR_ACK and WR_CFG_ACK ---
    # Drive SDA=0 continuously during all ACK slots (RTL has sda_oe=0 during these)
    # The RTL doesn't care about the ACK value for write ops (always proceeds),
    # but to be safe, drive 0 whenever sda_oe=0 and SCL is high until read phase.
    #
    # Strategy: wait for RD_ADDR_ACK (state=13). During all that time, drive SDA=0
    # whenever SCL is high and sda_oe=0 (covers both write ACKs and addr ACK).
    # Actually simpler: just drive SDA=0 for all ACK slots by monitoring SCL and oe.
    #
    # Even simpler: just wait for the ACK states directly.

    # Wait for WR_ADDR_ACK (state=4) then drive ACK
    ok = await wait_for_state(dut, 4, timeout=3000)  # WR_ADDR_ACK
    assert ok, "Slave: never entered WR_ADDR_ACK"
    # Drive SDA=0 during WR_ADDR_ACK's SCL high period
    dut.adc_sda.value = 0
    ok = await wait_for_state(dut, 5, timeout=1000)  # WR_CFG_BIT = next state
    assert ok, "Slave: never left WR_ADDR_ACK"
    dut.adc_sda.value = Z_VAL

    # Wait for WR_CFG_ACK (state=6) then drive ACK
    ok = await wait_for_state(dut, 6, timeout=3000)  # WR_CFG_ACK
    assert ok, "Slave: never entered WR_CFG_ACK"
    dut.adc_sda.value = 0
    ok = await wait_for_state(dut, 7, timeout=1000)  # REP_START_H = next state
    assert ok, "Slave: never left WR_CFG_ACK"
    dut.adc_sda.value = Z_VAL

    # Wait for RD_ADDR_ACK (state=13) then drive ACK
    ok = await wait_for_state(dut, RD_ADDR_ACK, timeout=3000)
    assert ok, "Slave: never entered RD_ADDR_ACK"
    dut.adc_sda.value = 0
    ok = await wait_for_state(dut, RD_BYTE1_BIT, timeout=1000)
    assert ok, "Slave: never left RD_ADDR_ACK"
    dut.adc_sda.value = Z_VAL

    # --- Step 4: Drive byte1 during RD_BYTE1_BIT ---
    # RTL is now in RD_BYTE1_BIT (state=14), phase=0, SCL about to rise.
    # drive_read_byte_in_state will drive 8 bits and wait for 8 SCL rise+fall pairs.
    bits1 = [(byte1 >> (7 - i)) & 1 for i in range(8)]
    for bit_val in bits1:
        dut.adc_sda.value = bit_val
        ok = await wait_scl_rise(dut)
        assert ok, "SCL didn't rise for byte1 bit"
        ok = await wait_scl_fall(dut)
        assert ok, "SCL didn't fall after byte1 bit"
    dut.adc_sda.value = Z_VAL
    # After 8 bits: SCL fell for bit_cnt=0 phase=1 → RTL enters RD_BYTE1_ACK

    # --- Step 5: Skip RD_BYTE1_ACK (master ACK — RTL drives SDA=0) ---
    ok = await wait_for_state(dut, RD_BYTE1_ACK, timeout=1000)
    assert ok, "Slave: never entered RD_BYTE1_ACK"
    ok = await wait_for_state(dut, RD_BYTE2_BIT, timeout=1000)
    assert ok, "Slave: never entered RD_BYTE2_BIT"

    # --- Step 6: Drive byte2 during RD_BYTE2_BIT ---
    bits2 = [(byte2 >> (7 - i)) & 1 for i in range(8)]
    for bit_val in bits2:
        dut.adc_sda.value = bit_val
        ok = await wait_scl_rise(dut)
        assert ok, "SCL didn't rise for byte2 bit"
        ok = await wait_scl_fall(dut)
        assert ok, "SCL didn't fall after byte2 bit"
    dut.adc_sda.value = Z_VAL
    # After 8 bits: RTL enters RD_NACK, then STOP, then pulses adc_valid


@cocotb.test()
async def tc1_read_sequence(dut):
    """TC1: Full I2C read transaction. Assert adc_data == 0x5A3 when adc_valid pulses."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    byte1 = 0x05   # channel=0, data[11:8]=5
    byte2 = 0xA3   # data[7:0]
    expected = ((byte1 & 0xF) << 8) | byte2  # 0x5A3

    cocotb.start_soon(i2c_slave_respond(dut, byte1=byte1, byte2=byte2))

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    adc_data_val = None
    for _ in range(25000):
        await RisingEdge(dut.clk)
        if int(dut.adc_valid.value) == 1:
            try:
                adc_data_val = int(dut.adc_data.value)
            except ValueError:
                adc_data_val = -1
                dut._log.warning("TC1: adc_data has X/Z at valid pulse")
            break

    assert adc_data_val is not None, "TC1 FAIL: adc_valid never pulsed"
    assert adc_data_val != -1, "TC1 FAIL: adc_data contains X/Z"
    dut._log.info(f"TC1: adc_data = 0x{adc_data_val:03X} (expected 0x{expected:03X})")
    assert adc_data_val == expected, \
        f"TC1 FAIL: got 0x{adc_data_val:03X}, expected 0x{expected:03X}"
    dut._log.info("TC1 PASS: I2C read sequence correct")


@cocotb.test()
async def tc2_scl_frequency(dut):
    """TC2: Measure SCL period. Assert = 250 clock cycles ± 2."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    cocotb.start_soon(i2c_slave_respond(dut))

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(1000):
        await RisingEdge(dut.clk)
        if scl_val(dut) == 0:
            break

    prev = scl_val(dut)
    rise1 = None
    rise2 = None
    cycle = 0
    for _ in range(2000):
        await RisingEdge(dut.clk)
        cycle += 1
        cur = scl_val(dut)
        if prev == 0 and cur == 1:
            if rise1 is None:
                rise1 = cycle
            elif rise2 is None:
                rise2 = cycle
                break
        prev = cur

    assert rise1 and rise2, "TC2 FAIL: couldn't find two SCL rising edges"
    period = rise2 - rise1
    dut._log.info(f"TC2: SCL period = {period} clock cycles (expected 250 ± 2)")
    assert 248 <= period <= 252, f"TC2 FAIL: SCL period = {period}, expected 250 ± 2"
    dut._log.info("TC2 PASS: SCL frequency correct (400 kHz)")


@cocotb.test()
async def tc3_valid_pulse_width(dut):
    """TC3: Assert adc_valid is HIGH for exactly 1 clock cycle."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    cocotb.start_soon(i2c_slave_respond(dut))

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    valid_cycles = 0
    for _ in range(25000):
        await RisingEdge(dut.clk)
        if int(dut.adc_valid.value) == 1:
            valid_cycles = 1
            for _ in range(10):
                await RisingEdge(dut.clk)
                if int(dut.adc_valid.value) == 1:
                    valid_cycles += 1
                else:
                    break
            break

    dut._log.info(f"TC3: adc_valid pulse width = {valid_cycles} cycle(s)")
    assert valid_cycles > 0, "TC3 FAIL: adc_valid never pulsed"
    assert valid_cycles == 1, f"TC3 FAIL: adc_valid high for {valid_cycles} cycles, expected 1"
    dut._log.info("TC3 PASS: adc_valid pulse width is exactly 1 cycle")
