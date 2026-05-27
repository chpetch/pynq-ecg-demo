"""
test_rpeak_detector.py — cocotb testbench for rpeak_detector
6 test cases as specified in agents/pynq_simulation.md

RTL notes:
- detection_threshold: input wire [11:0]
- ecg_sample: input wire [11:0]
- sample_valid: input wire (one-cycle pulse per sample)
- rpeak_detected: output reg (default 0, pulses 1 for one cycle on detection)
- bpm_out: output reg [7:0] (updated after BPM divider converges)
- Refractory period: 72 samples
- BPM = 21600 / interval using iterative divider
- Detection edge: ecg_sample > detection_threshold AND !prev_above AND !in_refractory
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz

# Threshold for testing — from algorithm_spec.md
DEFAULT_THRESHOLD = 2983


async def reset_dut(dut, threshold=DEFAULT_THRESHOLD):
    dut.rst_n.value = 0
    dut.ecg_sample.value = 0
    dut.sample_valid.value = 0
    dut.detection_threshold.value = threshold
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def send_sample(dut, value):
    """Send one sample via sample_valid pulse."""
    dut.ecg_sample.value = value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0


async def send_n_samples(dut, value, n):
    """Send n identical samples."""
    for _ in range(n):
        await send_sample(dut, value)
        await RisingEdge(dut.clk)  # gap between samples


async def count_rpeaks(dut, num_samples, between_gap=1):
    """Send num_samples zero-value samples, count rpeak_detected pulses."""
    count = 0
    for _ in range(num_samples):
        await send_sample(dut, 0)
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            count += 1
    return count


@cocotb.test()
async def tc1_single_peak_detected(dut):
    """TC1: Feed a pulse above threshold. Assert rpeak_detected pulses HIGH for exactly 1 cycle."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    threshold = DEFAULT_THRESHOLD
    dut.detection_threshold.value = threshold

    # Send a sample well above threshold
    peak_value = threshold + 500  # well above threshold

    # Need prev_above=0 (just reset), so first above-threshold sample triggers detection
    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    # Check rpeak_detected on next clock (it's registered, set in same cycle as sample_valid)
    rpeak_count = 0
    rpeak_seen = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            rpeak_seen = True
            rpeak_count += 1

    dut._log.info(f"TC1: rpeak_detected pulses = {rpeak_count}")
    assert rpeak_seen, "TC1 FAIL: rpeak_detected never pulsed"
    assert rpeak_count == 1, \
        f"TC1 FAIL: rpeak_detected was high for {rpeak_count} cycles, expected 1"

    dut._log.info("TC1 PASS: single R-peak detected for exactly 1 cycle")


@cocotb.test()
async def tc2_refractory_period(dut):
    """TC2: Two pulses 50 samples apart (< 72 refractory). Assert only one rpeak_detected."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    threshold = DEFAULT_THRESHOLD
    dut.detection_threshold.value = threshold
    peak_value = threshold + 500

    detected_count = 0

    # First peak
    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    # Send 50 zero samples (below threshold, within refractory)
    for i in range(50):
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected_count += 1
        await send_sample(dut, 0)
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected_count += 1

    # Second peak (within refractory period)
    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    # Wait a bit and count any more detections
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected_count += 1

    dut._log.info(f"TC2: total rpeak detections = {detected_count} (expected 1)")
    assert detected_count == 1, \
        f"TC2 FAIL: {detected_count} peaks detected, expected 1 (second should be in refractory)"

    dut._log.info("TC2 PASS: refractory period blocks second peak at 50 samples")


@cocotb.test()
async def tc3_two_peaks_detected(dut):
    """TC3: Two pulses 100 samples apart (> 72 refractory). Assert two rpeak_detected pulses."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    threshold = DEFAULT_THRESHOLD
    dut.detection_threshold.value = threshold
    peak_value = threshold + 500

    detected_count = 0

    async def send_and_count(value):
        nonlocal detected_count
        dut.ecg_sample.value = value
        dut.sample_valid.value = 1
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        dut.ecg_sample.value = 0
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected_count += 1

    # First peak
    await send_and_count(peak_value)

    # 100 zero samples
    for _ in range(100):
        await send_and_count(0)

    # Second peak
    await send_and_count(peak_value)

    # Wait a few more cycles
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected_count += 1

    dut._log.info(f"TC3: detected_count = {detected_count}")
    assert detected_count == 2, \
        f"TC3 FAIL: expected 2 peaks detected, got {detected_count}"

    dut._log.info("TC3 PASS: two peaks detected with 100-sample separation")


@cocotb.test()
async def tc4_bpm_calculation(dut):
    """TC4: Feed pulses at exactly 360-sample intervals (60 BPM).
    Assert bpm_out == 60 after second peak."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    threshold = 2000
    dut.detection_threshold.value = threshold
    peak_value = threshold + 500

    # First peak — seeds the interval counter
    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    # Send exactly 360 samples between peaks
    # interval_cnt starts at 0 after first peak, counts up each sample_valid
    # At second peak, interval_cnt = 360 → bpm = 21600/360 = 60
    for _ in range(360):
        await RisingEdge(dut.clk)
        dut.ecg_sample.value = 0
        dut.sample_valid.value = 1
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0

    # Second peak
    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    # Wait for BPM divider to complete: 21600/360=60 iterations
    # Each iteration takes 1 clock, so ~60-70 clocks
    for _ in range(200):
        await RisingEdge(dut.clk)

    bpm = int(dut.bpm_out.value)
    dut._log.info(f"TC4: bpm_out = {bpm} (expected 60)")
    assert bpm == 60, f"TC4 FAIL: bpm_out={bpm}, expected 60"

    dut._log.info("TC4 PASS: BPM calculation correct (60 BPM)")


@cocotb.test()
async def tc5_no_signal(dut):
    """TC5: Feed all-zero samples for 2000 cycles.
    Assert rpeak_detected never pulses, bpm_out stays 0."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.detection_threshold.value = DEFAULT_THRESHOLD

    detected = False
    for _ in range(2000):
        dut.ecg_sample.value = 0
        dut.sample_valid.value = 1
        await RisingEdge(dut.clk)
        dut.sample_valid.value = 0
        if int(dut.rpeak_detected.value) == 1:
            detected = True
        await RisingEdge(dut.clk)

    bpm = int(dut.bpm_out.value)
    dut._log.info(f"TC5: rpeak_detected ever = {detected}, final bpm_out = {bpm}")
    assert not detected, "TC5 FAIL: rpeak_detected pulsed on zero signal"
    assert bpm == 0, f"TC5 FAIL: bpm_out={bpm}, expected 0 for no-signal"

    dut._log.info("TC5 PASS: no detection on zero signal")


@cocotb.test()
async def tc6_configurable_threshold(dut):
    """TC6: Set detection_threshold=0xFFF. Feed sample=0xFFE. Assert no detection."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    dut.detection_threshold.value = 0xFFF  # Maximum threshold
    # 0xFFE < 0xFFF → condition (ecg_sample > detection_threshold) is FALSE
    peak_value = 0xFFE

    dut.ecg_sample.value = peak_value
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk)
    dut.sample_valid.value = 0
    dut.ecg_sample.value = 0

    detected = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.rpeak_detected.value) == 1:
            detected = True

    dut._log.info(f"TC6: detected with 0xFFE < threshold 0xFFF = {detected}")
    assert not detected, \
        f"TC6 FAIL: rpeak_detected pulsed for sample 0xFFE with threshold 0xFFF"

    dut._log.info("TC6 PASS: configurable threshold works (0xFFE not detected at threshold 0xFFF)")
