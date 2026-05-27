"""
test_spi_dac.py — cocotb testbench for spi_dac_driver
4 test cases as specified in agents/pynq_simulation.md

RTL notes:
- Module takes 8 channels (sample_data_0 .. sample_data_7)
- CS is dac_cs_n (not dac_sync_n)
- 8 channels × 24 bits = 192 bits total per sample_valid pulse
- SPI Mode 2: CPOL=1, CPHA=0; data captured on falling SCLK edge
- 24-bit word format: [23:20]=CMD(0011), [19:17]=CH, [16]=0, [15:4]=DATA, [3:0]=0000
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
CLK_PERIOD_NS = 10  # 100 MHz


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.sample_data_0.value = 0
    dut.sample_data_1.value = 0
    dut.sample_data_2.value = 0
    dut.sample_data_3.value = 0
    dut.sample_data_4.value = 0
    dut.sample_data_5.value = 0
    dut.sample_data_6.value = 0
    dut.sample_data_7.value = 0
    dut.sample_valid.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def pulse_valid(dut):
    """Pulse sample_valid for one clock cycle."""
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0


async def capture_channel_bits(dut, channel_idx=0):
    """
    Capture 24 bits of SPI data for a specific channel word.
    Data is sampled on FALLING edge of SCLK (SPI Mode 2).
    Returns the 24-bit integer captured.
    """
    bits = []
    # Wait for CS to go low (start of transfer)
    timeout = 500
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.dac_cs_n.value == 0:
            break
    else:
        raise AssertionError("CS never went low")

    # Skip channels 0..(channel_idx-1)
    for _ in range(channel_idx):
        for _ in range(24):
            # Wait for falling edge of SCLK
            prev = int(dut.dac_sclk.value)
            for _ in range(100):
                await RisingEdge(dut.clk)
                cur = int(dut.dac_sclk.value)
                if prev == 1 and cur == 0:
                    break
                prev = cur

    # Capture 24 bits on falling SCLK edges
    for _ in range(24):
        prev = int(dut.dac_sclk.value)
        for _ in range(100):
            await RisingEdge(dut.clk)
            cur = int(dut.dac_sclk.value)
            if prev == 1 and cur == 0:
                # Falling edge: sample DIN
                bits.append(int(dut.dac_din.value))
                break
            prev = cur

    assert len(bits) == 24, f"Only captured {len(bits)} bits"
    word = 0
    for b in bits:
        word = (word << 1) | b
    return word


@cocotb.test()
async def tc1_transfer_format(dut):
    """TC1: Apply sample_valid with sample_data_0=0xABC.
    Verify 24-bit word format for channel A."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.sample_data_0.value = 0xABC

    # Pulse sample_valid
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0

    # Capture the 24-bit word for channel 0
    word = await capture_channel_bits(dut, channel_idx=0)

    cmd  = (word >> 20) & 0xF
    ch   = (word >> 16) & 0xF
    data = (word >> 4) & 0xFFF
    dc   = word & 0xF

    dut._log.info(f"TC1: 24-bit word = 0x{word:06X}")
    dut._log.info(f"TC1: CMD={cmd:04b} CH={ch:04b} DATA=0x{data:03X} DC={dc:04b}")

    assert cmd == 0b0011, f"TC1 FAIL: CMD bits [23:20] = {cmd:04b}, expected 0011"
    assert ch == 0b0000, f"TC1 FAIL: CH bits [19:16] = {ch:04b}, expected 0000"
    assert data == 0xABC, f"TC1 FAIL: DATA bits [15:4] = 0x{data:03X}, expected 0xABC"
    assert dc == 0b0000, f"TC1 FAIL: DC bits [3:0] = {dc:04b}, expected 0000"

    dut._log.info("TC1 PASS: 24-bit SPI transfer format correct")


@cocotb.test()
async def tc2_sync_n_timing(dut):
    """TC2: Assert dac_cs_n (SYNC_N) goes LOW before first SCLK edge,
    stays LOW for all 192 bits (8 channels × 24 bits), goes HIGH after."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.sample_data_0.value = 0x555

    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0

    # Wait for CS to go low
    cs_went_low = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.dac_cs_n.value == 0:
            cs_went_low = True
            break

    assert cs_went_low, "TC2 FAIL: CS_N never went low"
    dut._log.info("TC2: CS_N went low")

    # Verify first SCLK edge happens AFTER CS_N went low
    # CS_N is already low, so check SCLK is still high (idle)
    assert int(dut.dac_sclk.value) == 1, "TC2 FAIL: SCLK not idle-HIGH when CS_N first went low"

    # Count falling SCLK edges — should be 192 (8ch × 24bits)
    falling_edges = 0
    cs_still_low = True
    for _ in range(10000):
        prev_sclk = int(dut.dac_sclk.value)
        await RisingEdge(dut.clk)
        cur_sclk = int(dut.dac_sclk.value)
        cur_cs = int(dut.dac_cs_n.value)

        if prev_sclk == 1 and cur_sclk == 0:
            # Falling edge
            assert cur_cs == 0, f"TC2 FAIL: CS_N went high before all bits at edge {falling_edges}"
            falling_edges += 1

        if cur_cs == 1:
            # CS deasserted
            break

    dut._log.info(f"TC2: falling SCLK edges = {falling_edges}")
    assert falling_edges == 192, \
        f"TC2 FAIL: expected 192 falling SCLK edges (8×24), got {falling_edges}"

    dut._log.info("TC2 PASS: SYNC_N (CS_N) timing correct")


@cocotb.test()
async def tc3_busy_flag(dut):
    """TC3: busy=1 immediately after sample_valid; busy=0 after full transfer."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    assert int(dut.busy.value) == 0, "TC3 FAIL: busy should be 0 initially"

    dut.sample_data_0.value = 0x123
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0

    # busy should go high on the very next cycle (ST_LOAD)
    await RisingEdge(dut.clk)
    busy_val = int(dut.busy.value)
    dut._log.info(f"TC3: busy right after valid = {busy_val}")
    assert busy_val == 1, f"TC3 FAIL: expected busy=1 right after sample_valid, got {busy_val}"

    # Wait for transfer to complete
    for _ in range(5000):
        await RisingEdge(dut.clk)
        if int(dut.busy.value) == 0:
            break

    dut._log.info(f"TC3: busy after transfer = {int(dut.busy.value)}")
    assert int(dut.busy.value) == 0, "TC3 FAIL: busy still high after transfer should be done"

    dut._log.info("TC3 PASS: busy flag correct")


@cocotb.test()
async def tc4_ignored_during_busy(dut):
    """TC4: Apply sample_valid twice in quick succession.
    Assert only one transfer occurs (second ignored while busy)."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.sample_data_0.value = 0xAAA

    # First sample_valid pulse
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    await RisingEdge(dut.clk)

    # Immediately apply second sample_valid while busy
    assert int(dut.busy.value) == 1, "TC4 FAIL: should be busy after first pulse"
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0

    # Count CS_N low-to-high transitions = number of transfers
    cs_transitions = 0
    prev_cs = 0  # CS is currently low (in transfer)
    for _ in range(10000):
        await RisingEdge(dut.clk)
        cur_cs = int(dut.dac_cs_n.value)
        if prev_cs == 0 and cur_cs == 1:
            cs_transitions += 1
        prev_cs = cur_cs

    dut._log.info(f"TC4: CS_N deasserts (complete transfers) = {cs_transitions}")
    assert cs_transitions == 1, \
        f"TC4 FAIL: expected 1 complete transfer, got {cs_transitions}"

    dut._log.info("TC4 PASS: second sample_valid correctly ignored while busy")
