# sim/Makefile — top-level runner for all cocotb testbenches
# Runs each sub-test in sequence using Icarus Verilog

.PHONY: all clean test_ecg_dds test_spi_dac test_i2c_adc test_fir_filter test_rpeak_detector test_axi_ecg_ctrl

all: test_ecg_dds test_spi_dac test_i2c_adc test_fir_filter test_rpeak_detector test_axi_ecg_ctrl

test_ecg_dds:
	$(MAKE) -C test_ecg_dds SIM=icarus

test_spi_dac:
	$(MAKE) -C test_spi_dac SIM=icarus

test_i2c_adc:
	$(MAKE) -C test_i2c_adc SIM=icarus

test_fir_filter:
	$(MAKE) -C test_fir_filter SIM=icarus

test_rpeak_detector:
	$(MAKE) -C test_rpeak_detector SIM=icarus

test_axi_ecg_ctrl:
	$(MAKE) -C test_axi_ecg_ctrl SIM=icarus

clean:
	$(MAKE) -C test_ecg_dds clean
	$(MAKE) -C test_spi_dac clean
	$(MAKE) -C test_i2c_adc clean
	$(MAKE) -C test_fir_filter clean
	$(MAKE) -C test_rpeak_detector clean
	$(MAKE) -C test_axi_ecg_ctrl clean
	rm -f results/*.vcd
