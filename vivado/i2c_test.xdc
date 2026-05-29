# i2c_test.xdc
# Project  : PYNQ-Z2 ECG Demo — I2C bring-up / scope harness (i2c_test_top)
# Purpose  : Pin constraints for the isolated i2c_adc_driver test bitstream.
#
# Reproduces the LAST-KNOWN-FAILING config from milestone_log Hardware Debug
# Session 2 (V10/W10 + internal PULLUP) so the first ILA capture shows the real
# failure, not a new variable. Do NOT change electrical settings here until the
# captured waveform has been read ("scope it first").
#
# PS7 DDR_* / FIXED_IO_* ports need no pin constraints — they map to dedicated
# Zynq MIO/DDR pads automatically via the processing_system7 IP.

# ==============================================================================
# JB Header — ADC I2C (i2c_adc_driver)
# ==============================================================================

# JB[2] — ADC_SCL (I2C clock, output) — physical pin JB3 = V10 (PMOD AD2 Pin 1)
set_property PACKAGE_PIN V10 [get_ports {adc_scl}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_scl}]
set_property DRIVE 8 [get_ports {adc_scl}]
set_property PULLTYPE PULLUP [get_ports {adc_scl}]

# JB[3] — ADC_SDA (I2C data, inout open-drain) — physical pin JB4 = W10 (PMOD AD2 Pin 2)
set_property PACKAGE_PIN W10 [get_ports {adc_sda}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_sda}]
set_property PULLTYPE PULLUP [get_ports {adc_sda}]

# ==============================================================================
# User LEDs — optional eyeball (LD0 = R14, LD1 = P14 on PYNQ-Z2)
# ==============================================================================
set_property PACKAGE_PIN R14 [get_ports {led[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN P14 [get_ports {led[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led[1]}]

# ==============================================================================
# DRC overrides
# ==============================================================================
# UCIO-1: adc_sda is an inout (open-drain I2C) — pin W10 IS constrained above.
# Downgrade Vivado's overly strict inout DRC to a warning so bitstream
# generation proceeds (Xilinx-recommended workaround).
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# ==============================================================================
# Unused-pin contention fix (the whole point of this rebuild)
# ==============================================================================
# Vivado's DEFAULT for unused device pins is a weak PULL-DOWN. The Pmod AD2
# internally bridges its top-row pins to the bottom-row pins, so SCL (V10) and
# SDA (W10) are each tied to an unused JB pin. With those bridged pins pulled
# DOWN by default, they fight our pull-ups and divide the line to a marginal
# voltage: the FPGA input still reads '1' (threshold ~1.4 V) but the AD7991's
# VIH (~2.31 V) sees an invalid level -> it never ACKs. The PYNQ base overlay
# floats all 8 JB pins, which is why Pmod_IIC works on the identical pins.
# Make every unused pin high-Z to match the base overlay and kill the divider.
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
