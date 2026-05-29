"""
test_axi_ecg_ctrl.py — cocotb testbench for axi_ecg_ctrl
8 test cases as specified in agents/pynq_simulation.md

Uses a manual AXI4-Lite driver (no cocotb-bus) for cocotb >= 2.0 compatibility.

Register map (offsets):
  0x00 BPM_CH_A  R/W  default 0x3C
  0x04 RR_FLUCT  R/W  default 0x00
  0x08 AMP_FLUCT R/W  default 0x00
  0x28 ECG_RAW   R/W  PS-written, pulses adc_valid_out for FIR downstream
  0x2C ECG_FILTERED R  read-only
  0x30 BPM_OUT   R    read-only
  0x34 RPEAK_COUNT R  read-only
  0x38 DETECT_THRESHOLD R/W default 0x800
  0x3C STATUS    R    read-only
  0x40 ECG_DAC   R    read-only
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
CLK_PERIOD_NS = 10


async def reset_dut(dut):
    """Reset the DUT and all inputs to default values."""
    dut.s_axi_aresetn.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awprot.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 1
    dut.s_axi_araddr.value = 0
    dut.s_axi_arprot.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 1
    dut.ecg_filt_in.value = 0
    dut.bpm_in.value = 0
    dut.rpeak_in.value = 0
    dut.dac_sample_in.value = 0
    await ClockCycles(dut.s_axi_aclk, 10)
    dut.s_axi_aresetn.value = 1
    await ClockCycles(dut.s_axi_aclk, 5)


async def axi_write(dut, addr, data, strb=0xF):
    """Perform an AXI4-Lite write transaction."""
    # Drive write address channel
    dut.s_axi_awaddr.value = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value = data
    dut.s_axi_wstrb.value = strb
    dut.s_axi_wvalid.value = 1

    # Wait for both AWREADY and WREADY
    aw_done = False
    w_done = False
    for _ in range(100):
        await RisingEdge(dut.s_axi_aclk)
        if int(dut.s_axi_awready.value) == 1:
            aw_done = True
            dut.s_axi_awvalid.value = 0
        if int(dut.s_axi_wready.value) == 1:
            w_done = True
            dut.s_axi_wvalid.value = 0
        if aw_done and w_done:
            break

    # Wait for write response
    for _ in range(100):
        await RisingEdge(dut.s_axi_aclk)
        if int(dut.s_axi_bvalid.value) == 1:
            break

    await RisingEdge(dut.s_axi_aclk)


async def axi_read(dut, addr):
    """Perform an AXI4-Lite read transaction. Returns read data.

    RTL asserts arready=1 and rvalid=1 in the same clock cycle when
    arvalid=1 and rvalid=0. We capture rdata in that cycle.
    """
    dut.s_axi_araddr.value = addr
    dut.s_axi_arvalid.value = 1

    rdata = None
    # Wait for ARREADY (and RVALID which arrives in same cycle)
    for _ in range(100):
        await RisingEdge(dut.s_axi_aclk)
        if int(dut.s_axi_arready.value) == 1:
            dut.s_axi_arvalid.value = 0
            # rvalid is also set this cycle; rdata is valid
            rdata = int(dut.s_axi_rdata.value)
            break

    # If we missed it same cycle, poll for rvalid
    if rdata is None:
        for _ in range(20):
            await RisingEdge(dut.s_axi_aclk)
            if int(dut.s_axi_rvalid.value) == 1:
                rdata = int(dut.s_axi_rdata.value)
                break

    assert rdata is not None, f"AXI read from 0x{addr:02X} timed out"
    await RisingEdge(dut.s_axi_aclk)
    return rdata


@cocotb.test()
async def tc1_write_bpm_ch_a(dut):
    """TC1: AXI write 0x3C to offset 0x00. Assert bpm_ch_a output == 0x3C."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    await axi_write(dut, 0x00, 0x3C, strb=0x1)

    # Wait a couple cycles for register to update
    await ClockCycles(dut.s_axi_aclk, 5)

    bpm_val = int(dut.bpm_ch_a.value)
    dut._log.info(f"TC1: bpm_ch_a = 0x{bpm_val:02X} (expected 0x3C)")
    assert bpm_val == 0x3C, f"TC1 FAIL: bpm_ch_a=0x{bpm_val:02X}, expected 0x3C"

    dut._log.info("TC1 PASS: BPM_CH_A write correct")


@cocotb.test()
async def tc2_write_rr_fluct(dut):
    """TC2: AXI write 0x80 to offset 0x04. Assert rr_fluct output == 0x80."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    await axi_write(dut, 0x04, 0x80, strb=0x1)
    await ClockCycles(dut.s_axi_aclk, 5)

    rr_val = int(dut.rr_fluct.value)
    dut._log.info(f"TC2: rr_fluct = 0x{rr_val:02X} (expected 0x80)")
    assert rr_val == 0x80, f"TC2 FAIL: rr_fluct=0x{rr_val:02X}, expected 0x80"

    dut._log.info("TC2 PASS: RR_FLUCT write correct")


@cocotb.test()
async def tc3_write_amp_fluct(dut):
    """TC3: AXI write 0x40 to offset 0x08. Assert amp_fluct output == 0x40."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    await axi_write(dut, 0x08, 0x40, strb=0x1)
    await ClockCycles(dut.s_axi_aclk, 5)

    amp_val = int(dut.amp_fluct.value)
    dut._log.info(f"TC3: amp_fluct = 0x{amp_val:02X} (expected 0x40)")
    assert amp_val == 0x40, f"TC3 FAIL: amp_fluct=0x{amp_val:02X}, expected 0x40"

    dut._log.info("TC3 PASS: AMP_FLUCT write correct")


@cocotb.test()
async def tc4_write_ecg_raw(dut):
    """TC4: AXI write 0xABC to ECG_RAW (0x28). Assert adc_data_out == 0xABC,
    adc_valid_out pulses for exactly 1 cycle, and read-back returns 0xABC."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    # Spawn a watcher that counts adc_valid_out high cycles
    valid_high_cycles = 0
    async def watch_valid():
        nonlocal valid_high_cycles
        for _ in range(40):
            await RisingEdge(dut.s_axi_aclk)
            if int(dut.adc_valid_out.value) == 1:
                valid_high_cycles += 1
    watcher = cocotb.start_soon(watch_valid())

    await axi_write(dut, 0x28, 0xABC)
    await ClockCycles(dut.s_axi_aclk, 5)

    adc_data = int(dut.adc_data_out.value)
    dut._log.info(f"TC4: adc_data_out = 0x{adc_data:03X} (expected 0xABC)")
    assert adc_data == 0xABC, \
        f"TC4 FAIL: adc_data_out=0x{adc_data:03X}, expected 0xABC"

    rdata = await axi_read(dut, 0x28)
    dut._log.info(f"TC4: read back ECG_RAW = 0x{rdata:08X} (expected 0x00000ABC)")
    assert rdata == 0x00000ABC, \
        f"TC4 FAIL: read-back 0x{rdata:08X}, expected 0x00000ABC"

    await watcher
    dut._log.info(f"TC4: adc_valid_out pulsed for {valid_high_cycles} cycle(s)")
    assert valid_high_cycles == 1, \
        f"TC4 FAIL: adc_valid_out high for {valid_high_cycles} cycles, expected 1"

    dut._log.info("TC4 PASS: ECG_RAW writable, adc_data_out updates, valid pulses 1 cycle")


@cocotb.test()
async def tc5_read_bpm_out(dut):
    """TC5: Drive bpm_in=75, AXI read offset 0x30. Assert == 0x0000004B."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.bpm_in.value = 75
    await ClockCycles(dut.s_axi_aclk, 5)

    rdata = await axi_read(dut, 0x30)
    dut._log.info(f"TC5: read BPM_OUT = 0x{rdata:08X} (expected 0x0000004B = 75)")
    assert rdata == 0x0000004B, \
        f"TC5 FAIL: BPM_OUT read 0x{rdata:08X}, expected 0x0000004B (75)"

    dut._log.info("TC5 PASS: BPM_OUT read correct")


@cocotb.test()
async def tc6_rpeak_count_increments(dut):
    """TC6: Pulse rpeak_in 3 times. AXI read offset 0x34. Assert == 3."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    # Pulse rpeak_in 3 times
    for _ in range(3):
        dut.rpeak_in.value = 1
        await RisingEdge(dut.s_axi_aclk)
        dut.rpeak_in.value = 0
        await RisingEdge(dut.s_axi_aclk)

    await ClockCycles(dut.s_axi_aclk, 3)

    rdata = await axi_read(dut, 0x34)
    dut._log.info(f"TC6: RPEAK_COUNT = 0x{rdata:08X} (expected 0x00000003)")
    assert rdata == 0x00000003, \
        f"TC6 FAIL: RPEAK_COUNT=0x{rdata:08X}, expected 0x00000003"

    dut._log.info("TC6 PASS: RPEAK_COUNT increments correctly")


@cocotb.test()
async def tc7_write_readonly_ignored(dut):
    """TC7: AXI write 0xDEAD to ECG_FILTERED (0x2C, read-only). Assert
    register continues to track ecg_filt_in. ECG_RAW used to be tested here
    but is now R/W (PS-written via AXI IIC IP); see TC4."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.ecg_filt_in.value = 0x123
    await ClockCycles(dut.s_axi_aclk, 5)

    # Try to write to read-only register at 0x2C
    await axi_write(dut, 0x2C, 0xDEAD)
    await ClockCycles(dut.s_axi_aclk, 5)

    rdata = await axi_read(dut, 0x2C)
    dut._log.info(f"TC7: ECG_FILTERED after write attempt = 0x{rdata:08X} (expected 0x00000123)")
    assert rdata == 0x00000123, \
        f"TC7 FAIL: ECG_FILTERED=0x{rdata:08X} after write, expected 0x00000123 (write should be ignored)"

    dut._log.info("TC7 PASS: write to read-only register ECG_FILTERED correctly ignored")


@cocotb.test()
async def tc8_default_values_on_reset(dut):
    """TC8: Assert rst_n=0, release. Read BPM_CH_A (0x00). Assert == 0x0000003C (default 60 BPM)."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, CLK_PERIOD_NS, units="ns").start())

    # Apply reset
    dut.s_axi_aresetn.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_bready.value = 1
    dut.s_axi_rready.value = 1
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awprot.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_arprot.value = 0
    dut.ecg_filt_in.value = 0
    dut.bpm_in.value = 0
    dut.rpeak_in.value = 0
    dut.dac_sample_in.value = 0
    await ClockCycles(dut.s_axi_aclk, 10)

    # Release reset
    dut.s_axi_aresetn.value = 1
    await ClockCycles(dut.s_axi_aclk, 5)

    # Read BPM_CH_A — should be default 0x3C = 60 BPM
    rdata = await axi_read(dut, 0x00)
    dut._log.info(f"TC8: BPM_CH_A after reset = 0x{rdata:08X} (expected 0x0000003C)")
    assert rdata == 0x0000003C, \
        f"TC8 FAIL: BPM_CH_A=0x{rdata:08X}, expected 0x0000003C (default 60 BPM)"

    dut._log.info("TC8 PASS: default reset value correct (BPM_CH_A = 0x3C)")
