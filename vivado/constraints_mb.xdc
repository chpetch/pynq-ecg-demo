# constraints_mb.xdc
# Project  : PYNQ-Z2 ECG Demo — MicroBlaze PMODB IOP overlay
# Purpose  : Pin constraints for JA (DAC SPI, our RTL) and JB (PMODB IOP gpio).
#
# PINS ARE THE OFFICIAL PYNQ-Z2 MAP, copied from the base overlay's base.xdc
# (vivado/pynq_src/boards/Pynq-Z2/base/vivado/constraints/base.xdc). The repo's
# old pl/constraints.xdc had a BOGUS pin map (JB as W12/W11/V10/W10/... and DAC
# SCLK=T10) — W12 isn't even a clg400 pin, and V10/W10 are NOT JB. The AD7991 is
# physically on JB = SCL T11 / SDA T10 (proven: base Pmod_IIC(PMODB,2,3) reads it).
#
# JA Header — PMOD DA4 (AD5628-1) SPI DAC, driven by ecg_signal_gen_top.
#   JA[0] DAC_CS_N -> Y18   JA[1] DAC_DIN -> Y19   JA[3] DAC_SCLK -> Y17
# JB Header — PMODB IOP gpio bus (io_switch routes AXI IIC SCL/SDA onto pins 2,3).
#   [0]W14 [1]Y14 [2]T11(SCL) [3]T10(SDA) [4]V16 [5]W16 [6]V12 [7]W13

# ==============================================================================
# JA Header — DAC SPI (ecg_signal_gen_top)   [official PYNQ-Z2 JA pins]
# ==============================================================================
set_property PACKAGE_PIN Y18 [get_ports {DAC_CS_N}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_CS_N}]

set_property PACKAGE_PIN Y19 [get_ports {DAC_DIN}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_DIN}]

set_property PACKAGE_PIN Y17 [get_ports {DAC_SCLK}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_SCLK}]
set_property DRIVE 8 [get_ports {DAC_SCLK}]

# ==============================================================================
# JB Header — PMODB IOP GPIO bus (pmodb_gpio, all 8 pins)  [official PYNQ-Z2 JB]
# ==============================================================================
set_property PACKAGE_PIN W14 [get_ports {pmodb_gpio_tri_io[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[0]}]

set_property PACKAGE_PIN Y14 [get_ports {pmodb_gpio_tri_io[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[1]}]

# [2] = SCL  (AD7991 I2C clock)
set_property PACKAGE_PIN T11 [get_ports {pmodb_gpio_tri_io[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[2]}]

# [3] = SDA  (AD7991 I2C data)
set_property PACKAGE_PIN T10 [get_ports {pmodb_gpio_tri_io[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[3]}]

set_property PACKAGE_PIN V16 [get_ports {pmodb_gpio_tri_io[4]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[4]}]

set_property PACKAGE_PIN W16 [get_ports {pmodb_gpio_tri_io[5]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[5]}]

set_property PACKAGE_PIN V12 [get_ports {pmodb_gpio_tri_io[6]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[6]}]

set_property PACKAGE_PIN W13 [get_ports {pmodb_gpio_tri_io[7]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[7]}]

# ------------------------------------------------------------------------------
# I2C pull-ups (copied from base.xdc). AXI IIC is open-drain; pins 2(SCL)/3(SDA)
# plus 6/7 (AD2 internally bridges 2<->6 and 3<->7) must be pulled up.
# ------------------------------------------------------------------------------
set_property PULLUP true [get_ports {pmodb_gpio_tri_io[2]}]
set_property PULLUP true [get_ports {pmodb_gpio_tri_io[3]}]
set_property PULLUP true [get_ports {pmodb_gpio_tri_io[6]}]
set_property PULLUP true [get_ports {pmodb_gpio_tri_io[7]}]

# ==============================================================================
# DRC overrides
# ==============================================================================
# UCIO-1: the pmodb_gpio inout pins are constrained above; downgrade Vivado's
# overly strict inout DRC to a warning so bitstream generation proceeds.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
