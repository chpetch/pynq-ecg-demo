TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/iobuf_stub.v $(shell pwd)/../../pl/i2c_adc_driver.v
TOPLEVEL = i2c_adc_driver
MODULE = test_i2c_adc
COCOTB_RESULTS_FILE = ../results/i2c_adc_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
