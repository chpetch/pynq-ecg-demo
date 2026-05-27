import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


@cocotb.test()
async def quick_waveform(dut):
    """Step through all 360 ROM addresses in 360 cycles to show ECG shape."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.bpm_config.value = 240   # fastest BPM — shortest sample interval
    dut.rr_fluct.value = 0
    dut.amp_fluct.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    # Wait for 2 full cardiac cycles at 240 BPM
    # sample interval = 100M / (240*6) = 69,444 cycles
    # 2 cycles * 360 samples = 720 samples * 69,444 = ~50M cycles
    pulses = 0
    for _ in range(51_000_000):
        await RisingEdge(dut.clk)
        if dut.sample_valid.value == 1:
            pulses += 1
        if pulses >= 720:
            break

    dut._log.info(f"Done — {pulses} samples captured")
