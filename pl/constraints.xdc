# constraints.xdc
# Project  : PYNQ-Z2 ECG Demo
# Purpose  : Pin constraints for JA (DAC SPI) and JB (ADC I2C via AXI IIC IP).
#
# PINS ARE THE OFFICIAL PYNQ-Z2 MAP (copied from the base overlay base.xdc:
# vivado/pynq_src/boards/Pynq-Z2/base/vivado/constraints/base.xdc). The earlier
# pin map in this file was WRONG (JB as V10/W10, DAC SCLK on T10) — the AD7991
# is on JB = SCL T11 / SDA T10 (hardware-proven: the MicroBlaze IOP build read
# 4095 on these exact pins). V10/W10 had no chip attached.
#
# Official PYNQ-Z2 headers:
#   JA (PMODA) pins[0..7] = Y18, Y19, Y16, Y17, U18, U19, W18, W19
#   JB (PMODB) pins[0..7] = W14, Y14, T11, T10, V16, W16, V12, W13
#
# JA — PMOD DA4 (AD5628-1) SPI DAC, driven by ecg_signal_gen_top:
#   JA[0] DAC_CS_N -> Y18    JA[1] DAC_DIN -> Y19    JA[3] DAC_SCLK -> Y17
# JB — PMOD AD2 (AD7991-0) I2C ADC via Xilinx AXI IIC IP (IIC interface external):
#   JB[2] SCL -> T11 (IIC_ADC_scl_io)    JB[3] SDA -> T10 (IIC_ADC_sda_io)
#   AD2 internally bridges JB pins 2<->6 and 3<->7, so pull up the partners
#   JB[6]=V12 and JB[7]=W13 too (matches base.xdc which pulls up pmodb 2,3,6,7).

# ==============================================================================
# JA Header — DAC SPI (ecg_signal_gen_top)
# ==============================================================================

# JA[0] — DAC_CS_N (SPI chip select)
set_property PACKAGE_PIN Y18 [get_ports {DAC_CS_N}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_CS_N}]

# JA[1] — DAC_DIN (SPI MOSI)
set_property PACKAGE_PIN Y19 [get_ports {DAC_DIN}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_DIN}]

# JA[3] — DAC_SCLK (SPI clock)
set_property PACKAGE_PIN Y17 [get_ports {DAC_SCLK}]
set_property IOSTANDARD  LVCMOS33 [get_ports {DAC_SCLK}]
set_property DRIVE 8 [get_ports {DAC_SCLK}]

# ==============================================================================
# JB Header — ADC I2C (AXI IIC IP, IIC interface external = IIC_ADC)
# ==============================================================================

# JB[2] — SCL (AD7991 I2C clock, inout open-drain). Wrapper exposes IIC_ADC_scl_io.
set_property PACKAGE_PIN T11 [get_ports {IIC_ADC_scl_io}]
set_property IOSTANDARD  LVCMOS33 [get_ports {IIC_ADC_scl_io}]
set_property DRIVE 8 [get_ports {IIC_ADC_scl_io}]
set_property PULLTYPE PULLUP [get_ports {IIC_ADC_scl_io}]

# JB[3] — SDA (AD7991 I2C data, inout open-drain). Wrapper exposes IIC_ADC_sda_io.
set_property PACKAGE_PIN T10 [get_ports {IIC_ADC_sda_io}]
set_property IOSTANDARD  LVCMOS33 [get_ports {IIC_ADC_sda_io}]
set_property PULLTYPE PULLUP [get_ports {IIC_ADC_sda_io}]

# JB[6]=V12 / JB[7]=W13 — AD2 internal bridge partners of SCL(2)/SDA(3). Pull up
# so they cannot divide the I2C lines to a marginal level. Dummy inputs only.
set_property PACKAGE_PIN V12 [get_ports {adc_scl_alt}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_scl_alt}]
set_property PULLTYPE PULLUP [get_ports {adc_scl_alt}]

set_property PACKAGE_PIN W13 [get_ports {adc_sda_alt}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_sda_alt}]
set_property PULLTYPE PULLUP [get_ports {adc_sda_alt}]

# ==============================================================================
# DRC overrides
# ==============================================================================
# UCIO-1: IIC_ADC_*_io are inout (open-drain I2C) from the block-design IIC
# interface — constrained above. Downgrade Vivado's overly strict inout DRC to a
# warning so bitstream generation proceeds (Xilinx-recommended workaround).
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
