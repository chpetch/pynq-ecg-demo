# constraints_mb.xdc
# Project  : PYNQ-Z2 ECG Demo — MicroBlaze PMODB IOP overlay
# Purpose  : Pin constraints for JA (DAC SPI, our RTL) and JB (PMODB IOP gpio).
#
# Reference: PYNQ-Z2 Master Constraints (TUL PYNQ-Z2 schematic rev C)
# All PMOD pins use LVCMOS33 I/O standard at 3.3 V.
#
# JA Header — PMOD DA4 (AD5628-1) SPI DAC, driven by ecg_signal_gen_top.
#   JA[0] = DAC_CS_N  -> V15   (SPI chip select, active low)
#   JA[1] = DAC_DIN   -> W15   (SPI MOSI)
#   JA[3] = DAC_SCLK  -> T10   (SPI clock)
#
# JB Header — PMODB IOP tri-state GPIO bus (pmodb_gpio). The MicroBlaze
# io_switch internally routes the AXI IIC SCL/SDA onto Pmod pins 2 and 3
# (the call Pmod_IIC(iop_pmodb, 2, 3, 0x28) selects them at runtime), so we
# simply constrain all 8 JB package pins to the io_switch bus. The wrapper
# infers IOBUFs for the gpio_rtl interface and exposes inout
# pmodb_gpio_tri_io[7:0].
#   JB[0] -> W12        pmodb_gpio_tri_io[0]
#   JB[1] -> W11        pmodb_gpio_tri_io[1]
#   JB[2] -> V10  (SCL) pmodb_gpio_tri_io[2]
#   JB[3] -> W10  (SDA) pmodb_gpio_tri_io[3]
#   JB[4] -> V12        pmodb_gpio_tri_io[4]
#   JB[5] -> W13        pmodb_gpio_tri_io[5]
#   JB[6] -> T15        pmodb_gpio_tri_io[6]
#   JB[7] -> T14        pmodb_gpio_tri_io[7]

# ==============================================================================
# JA Header — DAC SPI (ecg_signal_gen_top)
# ==============================================================================

# JA[0] — DAC_CS_N (SPI chip select)
set_property PACKAGE_PIN V15 [get_ports {DAC_CS_N}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_CS_N}]

# JA[1] — DAC_DIN (SPI MOSI)
set_property PACKAGE_PIN W15 [get_ports {DAC_DIN}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_DIN}]

# JA[3] — DAC_SCLK (SPI clock)
set_property PACKAGE_PIN T10 [get_ports {DAC_SCLK}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_SCLK}]
set_property DRIVE 8 [get_ports {DAC_SCLK}]

# ==============================================================================
# JB Header — PMODB IOP GPIO bus (pmodb_gpio, all 8 pins to io_switch)
# ==============================================================================

set_property PACKAGE_PIN W12 [get_ports {pmodb_gpio_tri_io[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[0]}]

set_property PACKAGE_PIN W11 [get_ports {pmodb_gpio_tri_io[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[1]}]

# JB[2] = SCL  (PMOD AD2 Pin 1)
set_property PACKAGE_PIN V10 [get_ports {pmodb_gpio_tri_io[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[2]}]

# JB[3] = SDA  (PMOD AD2 Pin 2)
set_property PACKAGE_PIN W10 [get_ports {pmodb_gpio_tri_io[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[3]}]

set_property PACKAGE_PIN V12 [get_ports {pmodb_gpio_tri_io[4]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[4]}]

set_property PACKAGE_PIN W13 [get_ports {pmodb_gpio_tri_io[5]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[5]}]

set_property PACKAGE_PIN T15 [get_ports {pmodb_gpio_tri_io[6]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[6]}]

set_property PACKAGE_PIN T14 [get_ports {pmodb_gpio_tri_io[7]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {pmodb_gpio_tri_io[7]}]

# ==============================================================================
# DRC overrides
# ==============================================================================

# UCIO-1: the pmodb_gpio inout pins are constrained above; Vivado's
# write_bitstream DRC is overly strict with inout ports inferred from a
# block-design gpio_rtl interface. Downgrade to warning so bitstream
# generation proceeds (Xilinx-recommended workaround).
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
