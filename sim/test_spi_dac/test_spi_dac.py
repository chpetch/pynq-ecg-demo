"""
test_spi_dac.py — cocotb testbench for spi_dac_driver (rev: AD5628 32-bit).

RTL behaviour under test:
- AD5628 32-bit words: [31:28]=DC [27:24]=CMD(0011) [23:20]=ADDR(=channel)
  [19:8]=DATA(12-bit) [7:0]=DC. SPI Mode 2 (CPOL=1/CPHA=0), sampled on falling SCLK.
- SYNC (dac_cs_n) is pulsed HIGH after EACH 32-bit word (one word per frame).
- The FIRST transfer after reset is preceded by a single reference-enable word
  0x08000001 (CMD 1000, enable internal 2.5 V ref); then the 8 channel words.
  Subsequent transfers are just the 8 channel words.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10            # 100 MHz
REF_WORD      = 0x08000001    # AD5628 internal-reference enable


async def reset_dut(dut):
    dut.rst_n.value = 0
    for i in range(8):
        getattr(dut, f"sample_data_{i}").value = 0
    dut.sample_valid.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def pulse_valid(dut):
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0


async def capture_word(dut, timeout=6000):
    """Wait for one SYNC frame: CS low -> 32 bits on falling SCLK -> CS high.
    Returns the 32-bit word."""
    for _ in range(timeout):                       # wait CS low
        await RisingEdge(dut.clk)
        if int(dut.dac_cs_n.value) == 0:
            break
    else:
        raise AssertionError("CS never went low")

    bits = []
    prev = int(dut.dac_sclk.value)
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        cur = int(dut.dac_sclk.value)
        if prev == 1 and cur == 0:                 # falling edge: chip samples DIN
            bits.append(int(dut.dac_din.value))
            if len(bits) == 32:
                break
        prev = cur
    assert len(bits) == 32, f"captured {len(bits)} bits, expected 32"

    for _ in range(timeout):                       # wait CS high (word latched)
        await RisingEdge(dut.clk)
        if int(dut.dac_cs_n.value) == 1:
            break

    word = 0
    for b in bits:
        word = (word << 1) | b
    return word


@cocotb.test()
async def tc1_format(dut):
    """First transfer = ref-enable word, then channel-A word in 32-bit format."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.sample_data_0.value = 0xABC
    await pulse_valid(dut)

    ref = await capture_word(dut)
    dut._log.info(f"TC1: word0 (ref) = 0x{ref:08X}")
    assert ref == REF_WORD, f"TC1 FAIL: first word 0x{ref:08X} != ref 0x{REF_WORD:08X}"

    chA = await capture_word(dut)
    cmd  = (chA >> 24) & 0xF
    addr = (chA >> 20) & 0xF
    data = (chA >> 8) & 0xFFF
    dut._log.info(f"TC1: word1 (chA) = 0x{chA:08X} cmd={cmd:04b} addr={addr:04b} data=0x{data:03X}")
    assert cmd  == 0b0011, f"TC1 FAIL: CMD {cmd:04b} != 0011"
    assert addr == 0,      f"TC1 FAIL: ADDR {addr} != 0 (channel A)"
    assert data == 0xABC,  f"TC1 FAIL: DATA 0x{data:03X} != 0xABC"
    dut._log.info("TC1 PASS: 32-bit format + ref-enable correct")


@cocotb.test()
async def tc2_frames_and_channels(dut):
    """First transfer is 9 SYNC frames (ref + 8 channels), each 32 bits, with the
    correct per-channel address and data."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    for i in range(8):
        getattr(dut, f"sample_data_{i}").value = 0x100 + i
    await pulse_valid(dut)

    words = [await capture_word(dut) for _ in range(9)]
    assert words[0] == REF_WORD, f"TC2 FAIL: word0 0x{words[0]:08X} != ref"
    for ch in range(8):
        w = words[1 + ch]
        cmd  = (w >> 24) & 0xF
        addr = (w >> 20) & 0xF
        data = (w >> 8) & 0xFFF
        assert cmd  == 0b0011,    f"TC2 FAIL ch{ch}: CMD {cmd:04b}"
        assert addr == ch,        f"TC2 FAIL ch{ch}: ADDR {addr}"
        assert data == 0x100 + ch, f"TC2 FAIL ch{ch}: DATA 0x{data:03X} != 0x{0x100+ch:03X}"
    dut._log.info("TC2 PASS: ref + 8 channel frames, addresses & data correct")


@cocotb.test()
async def tc3_busy(dut):
    """busy=0 at idle, 1 right after sample_valid, 0 after the transfer."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    assert int(dut.busy.value) == 0, "TC3 FAIL: busy not 0 at idle"
    await pulse_valid(dut)
    await RisingEdge(dut.clk)
    assert int(dut.busy.value) == 1, "TC3 FAIL: busy not 1 after sample_valid"

    for _ in range(60000):
        await RisingEdge(dut.clk)
        if int(dut.busy.value) == 0:
            break
    assert int(dut.busy.value) == 0, "TC3 FAIL: busy still high after transfer"
    dut._log.info("TC3 PASS: busy flag correct")


@cocotb.test()
async def tc4_ignored_during_busy(dut):
    """A second sample_valid asserted while busy is ignored — exactly one transfer
    (9 SYNC frames: ref + 8 channels) occurs."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.sample_data_0.value = 0xAAA
    await pulse_valid(dut)
    await RisingEdge(dut.clk)
    assert int(dut.busy.value) == 1, "TC4 FAIL: not busy after first pulse"
    await pulse_valid(dut)                      # second pulse while busy -> ignored

    words = 0
    prev_cs = 0                                 # currently low (mid-frame)
    for _ in range(60000):
        await RisingEdge(dut.clk)
        cs = int(dut.dac_cs_n.value)
        if prev_cs == 0 and cs == 1:
            words += 1
        prev_cs = cs
        if int(dut.busy.value) == 0 and cs == 1:
            break
    dut._log.info(f"TC4: SYNC frames in the single transfer = {words}")
    assert words == 9, f"TC4 FAIL: expected 9 frames (ref+8ch), got {words}"
    dut._log.info("TC4 PASS: second sample_valid ignored while busy")
