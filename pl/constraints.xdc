# constraints.xdc
# Project  : PYNQ-Z2 ECG Demo
# Agent    : pynq_ecg_process
# Purpose  : Pin constraints for JA (DAC SPI) and JB (ADC I2C) PMOD headers
#
# Reference: PYNQ-Z2 Master Constraints (TUL PYNQ-Z2 schematic rev C)
# All PMOD pins use LVCMOS33 I/O standard at 3.3 V.
#
# JA Header — PMOD DA4 (AD5628-1) SPI DAC
#   JA[0] = DAC_CS_N   (SPI chip select, active low)
#   JA[1] = DAC_DIN    (SPI MOSI)
#   JA[3] = DAC_SCLK   (SPI clock)
#   JA[2] = (unused)
#
# JB Header — PMOD AD2 (AD7991-0) I2C ADC
#   JB[0] = ADC_SDA    (I2C data, bidirectional open-drain)
#   JB[1] = ADC_SCL    (I2C clock, output)
#   JB[2] = (unused)
#   JB[3] = (unused)
#
# PYNQ-Z2 JA schematic net names and package pins:
#   JA1 / JA[0]  -> V15
#   JA2 / JA[1]  -> W15
#   JA3 / JA[2]  -> T11  (unused)
#   JA4 / JA[3]  -> T10
#   JA7 / JA[4]  -> W14  (unused)
#   JA8 / JA[5]  -> Y14  (unused)
#   JA9 / JA[6]  -> T12  (unused)
#   JA10/ JA[7]  -> U12  (unused)
#
# PYNQ-Z2 JB schematic net names and package pins:
#   JB1 / JB[0]  -> W12
#   JB2 / JB[1]  -> W11
#   JB3 / JB[2]  -> V10  (unused)
#   JB4 / JB[3]  -> W10  (unused)
#   JB7 / JB[4]  -> V12  (unused)
#   JB8 / JB[5]  -> W13  (unused)
#   JB9 / JB[6]  -> T15  (unused)
#   JB10/ JB[7]  -> T14  (unused)

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
# JB Header — ADC I2C (ecg_process_top)
# ==============================================================================

# JB[0] — ADC_SDA (I2C data, bidirectional)
set_property PACKAGE_PIN W12 [get_ports {adc_sda}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_sda}]

# JB[1] — ADC_SCL (I2C clock, output)
set_property PACKAGE_PIN W11 [get_ports {adc_scl}]
set_property IOSTANDARD  LVCMOS33 [get_ports {adc_scl}]
set_property DRIVE 8 [get_ports {adc_scl}]
