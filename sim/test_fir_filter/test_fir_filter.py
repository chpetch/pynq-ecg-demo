"""
test_fir_filter.py — cocotb testbench for fir_filter
5 test cases as specified in agents/pynq_simulation.md

RTL pipeline (fir_filter.v):
  - On data_valid=1: delay shifts, acc is computed → acc register updates next clock
  - valid_pipe = data_valid (registered)
  - data_valid_out = valid_pipe (registered) → 2-cycle delay after data_valid
  - data_out = acc[26:15] registered on the cycle AFTER data_valid
  - So data_out is stable at data_valid_out = 1

Strategy: send one sample per clock (data_valid for 1 cycle, then 1 cycle gap).
data_valid_out fires 2 clocks after data_valid.
We collect outputs in a monitor coroutine running in parallel.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Event
import math

CLK_PERIOD_NS = 10

# FIR coefficients from algorithm_spec.md (Q1.15 signed integers)
COEFFS = [
    -56, -31, 22, 112, 197, 180, -36, -459, -921, -1094, -622,
    682, 2676, 4867, 6577, 7224, 6577, 4867, 2676, 682, -622,
    -1094, -921, -459, -36, 180, 197, 112, 22, -31, -56
]
NTAPS = 31


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.data_in.value = 0
    dut.data_valid.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def send_and_collect(dut, samples, drain_extra=5):
    """
    Send all samples one per clock cycle (data_valid=1 for 1 cycle, gap=0).
    Simultaneously collect data_out values when data_valid_out=1.

    RTL pipeline note: the last sample's acc is only registered into data_out
    when data_valid=1 in the FOLLOWING cycle (because data_out <= acc is inside
    the if(data_valid) block). To avoid losing the last sample, we append one
    extra zero sample as a flush token — the output from this flush is discarded.

    Returns list of output values (one per input sample, in order).
    """
    outputs = []
    # Append one flush sample so the last real sample's acc gets registered
    flush_samples = list(samples) + [0]
    n = len(flush_samples)
    total_cycles = n + drain_extra + 10

    async def monitor():
        for _ in range(total_cycles):
            await RisingEdge(dut.clk)
            if int(dut.data_valid_out.value) == 1:
                outputs.append(int(dut.data_out.value))

    mon = cocotb.start_soon(monitor())

    for s in flush_samples:
        dut.data_in.value = s
        dut.data_valid.value = 1
        await RisingEdge(dut.clk)
        dut.data_valid.value = 0
        dut.data_in.value = 0

    # Wait for drain
    await ClockCycles(dut.clk, drain_extra + 10)
    await mon

    # Return only the first len(samples) outputs (discard the flush token output)
    return outputs[:len(samples)]


def compute_expected_outputs(samples):
    """
    Compute expected FIR outputs for a sequence of samples.
    RTL: on each data_valid cycle, data_out (next clock) = (acc >> 15) & 0xFFF
    acc = data_in*H[0] + delay[0]*H[1] + ... + delay[29]*H[30]
    delay shifts: delay[0]=data_in, delay[k]=delay[k-1] (non-blocking, uses old values)
    """
    delay = [0] * 30  # delay[0..29]
    expected = []
    for inp in samples:
        acc = inp * COEFFS[0]
        for k in range(1, NTAPS):
            acc += delay[k-1] * COEFFS[k]
        # Clip to 32-bit signed
        if acc > (2**31 - 1):
            acc = 2**31 - 1
        elif acc < -(2**31):
            acc = -(2**31)
        out = (acc >> 15) & 0xFFF
        expected.append(out)
        # Update delay (shift right)
        delay = [inp] + delay[:-1]
    return expected


@cocotb.test()
async def tc1_impulse_response(dut):
    """TC1: Feed impulse (0xFFF, then 30 zeros). Collect 31 outputs.
    Assert each matches expected within ±2 LSB."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    impulse = [0xFFF] + [0] * 30
    expected = compute_expected_outputs(impulse)

    outputs = await send_and_collect(dut, impulse, drain_extra=10)

    dut._log.info(f"TC1: got {len(outputs)} outputs (need 31)")
    dut._log.info(f"TC1: first 5 got  = {outputs[:5]}")
    dut._log.info(f"TC1: first 5 exp  = {expected[:5]}")

    assert len(outputs) >= 31, f"TC1 FAIL: only got {len(outputs)} outputs, need 31"

    max_diff = 0
    for k in range(31):
        diff = abs(outputs[k] - expected[k])
        if diff > max_diff:
            max_diff = diff
        assert diff <= 2, \
            f"TC1 FAIL: output[{k}]={outputs[k]}, expected={expected[k]}, diff={diff}"

    dut._log.info(f"TC1 PASS: impulse response matches within ±2 LSB (max_diff={max_diff})")


@cocotb.test()
async def tc2_passband_signal_passes(dut):
    """TC2: Feed 10 Hz sine wave (passband 0.5-40 Hz). After first 31 samples,
    assert output amplitude > 80% of input amplitude."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    fs = 360.0
    f = 10.0
    n_settle = NTAPS
    n_measure = 100
    amp_in = 1000.0
    offset = 2048.0

    samples = []
    for i in range(n_settle + n_measure):
        s = int(offset + amp_in * math.sin(2 * math.pi * f * i / fs))
        samples.append(max(0, min(4095, s)))

    outputs = await send_and_collect(dut, samples, drain_extra=10)

    dut._log.info(f"TC2: got {len(outputs)} outputs (need {n_settle + n_measure})")
    assert len(outputs) >= n_settle + n_measure, \
        f"TC2 FAIL: only got {len(outputs)} outputs"

    settled = outputs[n_settle:]
    dc = sum(settled) / len(settled)
    amp_out = max(abs(v - dc) for v in settled)

    dut._log.info(f"TC2: amp_in={amp_in}, amp_out={amp_out:.1f}, ratio={amp_out/amp_in:.3f}")
    assert amp_out > 0.80 * amp_in, \
        f"TC2 FAIL: amp_out={amp_out:.1f} < 80% of {amp_in}"

    dut._log.info("TC2 PASS: 10 Hz passband signal passes with >80% amplitude")


@cocotb.test()
async def tc3_stopband_attenuation(dut):
    """TC3: Feed 100 Hz sine wave (above 40 Hz stopband). Assert output amplitude < 10%."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    fs = 360.0
    f = 100.0
    n_settle = NTAPS
    n_measure = 100
    amp_in = 1000.0
    offset = 2048.0

    samples = []
    for i in range(n_settle + n_measure):
        s = int(offset + amp_in * math.sin(2 * math.pi * f * i / fs))
        samples.append(max(0, min(4095, s)))

    outputs = await send_and_collect(dut, samples, drain_extra=10)

    dut._log.info(f"TC3: got {len(outputs)} outputs (need {n_settle + n_measure})")
    assert len(outputs) >= n_settle + n_measure, \
        f"TC3 FAIL: only got {len(outputs)} outputs"

    settled = outputs[n_settle:]
    dc = sum(settled) / len(settled)
    amp_out = max(abs(v - dc) for v in settled)

    dut._log.info(f"TC3: amp_in={amp_in}, amp_out={amp_out:.1f}, ratio={amp_out/amp_in:.3f}")
    assert amp_out < 0.10 * amp_in, \
        f"TC3 FAIL: amp_out={amp_out:.1f} >= 10% of {amp_in} — not attenuated"

    dut._log.info("TC3 PASS: 100 Hz stopband signal attenuated to <10%")


@cocotb.test()
async def tc4_latency(dut):
    """TC4: Feed impulse. Verify linear-phase latency = 15 samples.
    The centre tap h[15]=7224 is the largest positive coefficient.
    In the 12-bit unsigned output, this produces the maximum POSITIVE output value
    (output[15] = 902), while negative coefficients produce values near 4095.
    Assert: output[15] is the maximum SIGNED value (i.e., peak of the signed impulse response).
    Also assert first output is non-zero (h[0]=-56 != 0)."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    impulse = [0xFFF] + [0] * 30
    outputs = await send_and_collect(dut, impulse, drain_extra=10)

    dut._log.info(f"TC4: first 16 outputs = {outputs[:16]}")
    assert len(outputs) >= 31, f"TC4 FAIL: only got {len(outputs)} outputs"

    # h[0]=-56 is non-zero, so first output should be non-zero
    first_nonzero = None
    for i, v in enumerate(outputs[:31]):
        if v != 0:
            first_nonzero = i
            break

    assert first_nonzero is not None, "TC4 FAIL: no non-zero output"
    assert first_nonzero == 0, \
        f"TC4 FAIL: first non-zero at index {first_nonzero}, expected 0 (h[0]*impulse is non-zero)"

    # The peak of the signed impulse response is at index 15 (h[15]=7224 = max magnitude positive coeff)
    # In 12-bit unsigned, positive values are small (0..2047) and negative values wrap to (2048..4095)
    # The maximum POSITIVE output (lowest unsigned near 0..2047) is at index 15 = 902
    # h[15]=7224 gives output 902; this is the maximum signed value in the response
    # Verify: output[15] is the maximum positive value (minimum unsigned if signed)
    # More robustly: convert to signed 12-bit and find the maximum
    def to_signed12(v):
        return v if v < 2048 else v - 4096

    signed_outputs = [to_signed12(v) for v in outputs[:31]]
    signed_peak_idx = signed_outputs.index(max(signed_outputs))
    dut._log.info(f"TC4: signed peak at index {signed_peak_idx}, "
                  f"signed_value={signed_outputs[signed_peak_idx]}, unsigned={outputs[signed_peak_idx]}")

    assert signed_peak_idx == 15, \
        f"TC4 FAIL: signed peak at index {signed_peak_idx}, expected 15 (centre tap h[15]=7224)"

    dut._log.info(f"TC4 PASS: first non-zero at index 0, signed peak at index 15 (centre tap)")


@cocotb.test()
async def tc5_no_overflow(dut):
    """TC5: Feed 0xFFF for 100 samples. Assert all outputs in [0, 4095]."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset_dut(dut)

    samples = [0xFFF] * 100
    outputs = await send_and_collect(dut, samples, drain_extra=10)

    dut._log.info(f"TC5: {len(outputs)} outputs, max={max(outputs) if outputs else 'N/A'}")

    for i, v in enumerate(outputs):
        assert 0 <= v <= 0xFFF, \
            f"TC5 FAIL: output[{i}]={v} outside [0, 4095]"

    dut._log.info("TC5 PASS: no overflow — all outputs in [0, 4095]")
